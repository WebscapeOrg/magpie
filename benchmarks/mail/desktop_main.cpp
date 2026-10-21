#include <QDateTime>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QtQuickTest/quicktest.h>
#include <QTest>
#include <QWindow>

class DesktopProbe : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap options READ options CONSTANT)
    Q_PROPERTY(qint64 launchedAt READ launchedAt CONSTANT)
public:
    using QObject::QObject;
    static inline qint64 launched = QDateTime::currentMSecsSinceEpoch();
    QVariantMap options() const {
        QFile file(qEnvironmentVariable("MAGPIE_DESKTOP_OPTIONS"));
        if (!file.open(QIODevice::ReadOnly)) qFatal("Missing desktop fixture options");
        return QJsonDocument::fromJson(file.readAll()).object().toVariantMap();
    }
    qint64 launchedAt() const { return launched; }
    Q_INVOKABLE void capture(const QString &kind, qint64 started, int serial) {
        const auto record = QJsonObject{{"kind", kind}, {"started", started}, {"serial", serial}};
        qInfo().noquote() << "DESKTOP_CAPTURE" << QJsonDocument(record).toJson(QJsonDocument::Compact);
    }
    Q_INVOKABLE bool captured(int serial) {
        return QFile::exists(options().value("output").toString() + "/capture-" + QString::number(serial));
    }
    Q_INVOKABLE void checkpoint(const QString &name) {
        qInfo().noquote() << "DESKTOP_CHECKPOINT" << name;
    }
    Q_INVOKABLE bool checkpointComplete(const QString &name) {
        return QFile::exists(options().value("output").toString() + "/" + name + ".done");
    }
    Q_INVOKABLE void press(QObject *window, int key) {
        auto *target = qobject_cast<QWindow *>(window);
        if (!target) qFatal("Desktop key target must be a window");
        QTest::keyClick(target, static_cast<Qt::Key>(key));
    }
};

class DesktopSetup : public QObject {
    Q_OBJECT
public slots:
    void applicationAvailable() {
        QCoreApplication::setApplicationName("Magpie acceptance");
        QQuickStyle::setStyle("Omamail");
        QQuickStyle::setFallbackStyle("Basic");
        qmlRegisterSingletonType<DesktopProbe>("Magpie.Acceptance", 1, 0, "Probe",
            [](QQmlEngine *, QJSEngine *) -> QObject * { return new DesktopProbe; });
    }
    void qmlEngineAvailable(QQmlEngine *engine) {
        engine->addImportPath(QStringLiteral(OMAMAIL_SOURCE_ROOT) + "/app/qml/imports");
        engine->addImportPath(QStringLiteral(OMAMAIL_SOURCE_ROOT) + "/app/qml/styles");
    }
};

QUICK_TEST_MAIN_WITH_SETUP(desktop_acceptance, DesktopSetup)
#include "desktop_main.moc"
