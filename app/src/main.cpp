#include "activation.h"
#include "app_icon.h"
#include "application_host.h"
#include "notifications.h"
#include "resource_check.h"
#include "window.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTextStream>
#include <QWindow>

namespace {
int reportResourceCheck(const ResourcePaths &paths)
{
    const ResourceCheck result = checkResources(paths);
    if (result.ok) return 0;
    QTextStream stream(stderr);
    for (const QString &error : result.errors) stream << error << Qt::endl;
    return 1;
}
}

int main(int argc, char *argv[])
{
    QList<QByteArray> arguments;
    for (int argumentIndex = 1; argumentIndex < argc; ++argumentIndex)
        arguments.append(QByteArray(argv[argumentIndex]));
    const LaunchOptions launch = parseLaunchArguments(arguments);
    if (!launch.ok) {
        QTextStream(stderr) << launch.error << Qt::endl;
        return 2;
    }

    QCoreApplication::setOrganizationName(QStringLiteral("Omamail"));
    // Invariant: Qt's internal application name keeps omamail's settings and notification
    // route locations stable. The display name is the user-facing Magpie Mail brand.
    QCoreApplication::setApplicationName(QStringLiteral("Omamail"));
    QCoreApplication::setApplicationVersion(QStringLiteral(OMAMAIL_APP_VERSION));

    if (launch.action == LaunchOptions::Action::CheckResources) {
        QCoreApplication application(argc, argv);
        return reportResourceCheck(defaultResourcePaths({}, developmentResourcesEnabled()));
    }

    const bool smokeTest = launch.action == LaunchOptions::Action::SmokeTest;
    if (smokeTest && qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", "offscreen");
    QQuickWindow::setDefaultAlphaBuffer(false);
    ActivationChannel activationChannel;
    activationChannel.suspendDelivery();
    QGuiApplication application(argc, argv);
    application.installEventFilter(&activationChannel);
    QGuiApplication::setApplicationDisplayName(QStringLiteral("Magpie Mail"));
    // Invariant: The host decides when the process ends: the app menu's Quit, or the
    // shell hiding a window it has no way to bring back. Qt's own reflex of
    // quitting once the last window is hidden would turn Cmd+W into Cmd+Q.
    application.setQuitOnLastWindowClosed(false);
    // Invariant: Every native surface uses Apple's envelope artwork. A packaged
    // macOS app takes it from CFBundleIconFile; development and other platforms
    // load the same reviewed image from the compiled resources.
#ifdef Q_OS_MACOS
    if (!QCoreApplication::applicationDirPath().endsWith(QStringLiteral(".app/Contents/MacOS")))
        application.setWindowIcon(iconFromIcnsFile(QStringLiteral(
            ":/omamail/app/resources/macos/omamail.icns")));
#else
    application.setWindowIcon(QIcon(QStringLiteral(
        ":/omamail/ui/assets/magpie-mail.png")));
#endif
    const ResourcePaths paths = defaultResourcePaths({}, developmentResourcesEnabled());
    if (smokeTest) {
        QString error;
        if (runSmokeTest(paths, launch.smokeReadyFile, &error)) return 0;
        QTextStream(stderr) << error << Qt::endl;
        return 1;
    }
    if (const int status = reportResourceCheck(paths); status != 0) return status;

    ActivationChannel::Role role;
    QString activationError;
    if (!activationChannel.acquire(launch.activationPayload, &role,
                                   &activationError)) {
        QTextStream(stderr) << activationError << Qt::endl;
        return 1;
    }
    if (role == ActivationChannel::Role::Secondary) {
        const QStringList earlyEvents = activationChannel.takePendingActivations();
        for (const QString &payload : earlyEvents) {
            if (activationChannel.handOff(payload, &activationError)
                == ActivationChannel::HandoffResult::Acknowledged) continue;
            if (activationError.isEmpty())
                activationError = QStringLiteral("Could not forward an early file-open event");
            QTextStream(stderr) << activationError << Qt::endl;
            return 1;
        }
        return 0;
    }
    // Invariant: Apple mailto events and command-line launches share the same bounded
    // activation queue. Linux desktop files supply the URL as one argument instead.
    application.setProperty("magpieMailInitialActivation", launch.activationPayload);
    application.setProperty("magpieMailStartInBackground",
                            launch.action == LaunchOptions::Action::Background);
    initializeNotificationActivation();

    // Invariant: Native platform styles can draw a light system scrollbar over a dark
    // Omarchy palette. Keep controls in the standalone process on our small
    // semantic style; the shell plugin continues to use the shell's style.
    QQuickStyle::setStyle(QStringLiteral("Omamail"));
    QQuickStyle::setFallbackStyle(QStringLiteral("Basic"));

    QQmlApplicationEngine engine;
    engine.addImportPath(QFileInfo(paths.sharedUi).absolutePath());
    engine.addImportPath(paths.standaloneQml.startsWith(QStringLiteral(":"))
        ? QStringLiteral("qrc:/omamail/app/qml/imports")
        : QFileInfo(paths.standaloneQml).dir().filePath(QStringLiteral("imports")));
    engine.addImportPath(paths.standaloneQml.startsWith(QStringLiteral(":"))
        ? QStringLiteral("qrc:/omamail/app/qml/styles")
        : QFileInfo(paths.standaloneQml).dir().filePath(QStringLiteral("styles")));
    const QUrl mainUrl = paths.standaloneQml.startsWith(QStringLiteral(":"))
        ? QUrl(QStringLiteral("qrc") + paths.standaloneQml)
        : QUrl::fromLocalFile(paths.standaloneQml);
    auto *host = engine.singletonInstance<ApplicationHost *>(
        QStringLiteral("Omamail.Native"), QStringLiteral("NativeHost"));
    if (!host) {
        activationChannel.rejectPendingActivations();
        return 1;
    }
    QString statusError;
    if (!host->configureStatusWriter(activationChannel.runtimeDirectory(), &statusError)) {
        QTextStream(stderr) << statusError << Qt::endl;
        activationChannel.rejectPendingActivations();
        return 1;
    }
    engine.load(mainUrl);
    if (engine.rootObjects().isEmpty()) {
        activationChannel.rejectPendingActivations();
        return 1;
    }
    for (QObject *object : engine.rootObjects()) {
        if (auto *window = qobject_cast<QWindow *>(object)) {
            prepareNativeWindow(window);
            watchNativeCloseChord(window, [host] { host->requestClose(); });
        }
    }
    // Invariant: The ready host consumes every buffered payload before its waiting
    // launcher receives a positive acknowledgement. Any earlier return rejects them.
    QObject::connect(&activationChannel, &ActivationChannel::activationRequested,
                     host, &ApplicationHost::activate);
    if (!activationChannel.enableDelivery()) return 1;
    return application.exec();
}
