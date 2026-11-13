#include "activation.h"
#include "application_host.h"
#include "runtime.h"
#include "status_file.h"

#include <QDateTime>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileOpenEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QtEndian>

#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

#ifndef Q_OS_WIN
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace {
QString runtimePath(QTemporaryDir &directory)
{
    return directory.filePath(QStringLiteral("magpie-mail"));
}

QByteArray testFrame(const QByteArray &payload)
{
    QByteArray frame(sizeof(quint32), Qt::Uninitialized);
    qToBigEndian(static_cast<quint32>(payload.size()),
                 reinterpret_cast<uchar *>(frame.data()));
    return frame + payload;
}

QJsonObject statusAt(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(file.readAll()).object();
}

bool readAcknowledgement(QLocalSocket &socket, bool *accepted)
{
    QDeadlineTimer deadline(2000);
    QByteArray response;
    while (!deadline.hasExpired()) {
        if (socket.bytesAvailable() == 0)
            socket.waitForReadyRead(qMax(1, static_cast<int>(
                qMin<qint64>(10, deadline.remainingTime()))));
        QCoreApplication::processEvents();
        response.append(socket.readAll());
        if (response.size() < static_cast<qsizetype>(sizeof(quint32))) continue;
        quint32 networkLength = 0;
        std::memcpy(&networkLength, response.constData(), sizeof(networkLength));
        const quint32 length = qFromBigEndian(networkLength);
        if (length == 0 || length > 124) return false;
        if (response.size() < static_cast<qsizetype>(sizeof(quint32) + length)) continue;
        if (response.size() != static_cast<qsizetype>(sizeof(quint32) + length)) return false;
        const QJsonDocument document = QJsonDocument::fromJson(response.mid(sizeof(quint32)));
        const QJsonObject object = document.object();
        if (!document.isObject() || object.size() != 1
            || !object.value(QStringLiteral("accepted")).isBool()) return false;
        *accepted = object.value(QStringLiteral("accepted")).toBool();
        return true;
    }
    return false;
}

bool acknowledged(QLocalSocket &socket)
{
    bool accepted = false;
    return readAcknowledgement(socket, &accepted) && accepted;
}

class ConcurrentLauncher final : public QThread {
public:
    ConcurrentLauncher(QString runtimeDirectory, std::atomic<bool> &start,
                       std::atomic<bool> &releasePrimary, std::atomic<int> &completed)
        : m_runtimeDirectory(std::move(runtimeDirectory)), m_start(start),
          m_releasePrimary(releasePrimary), m_completed(completed)
    {
    }

    bool acquired = false;
    ActivationChannel::Role role = ActivationChannel::Role::Primary;
    QString error;

    void run() override
    {
        ActivationChannel channel(m_runtimeDirectory);
        while (!m_start.load(std::memory_order_acquire)) std::this_thread::yield();
        acquired = channel.acquire(QStringLiteral("{}"), &role, &error);
        m_completed.fetch_add(1, std::memory_order_release);
        if (!acquired || role != ActivationChannel::Role::Primary) return;
        while (!m_releasePrimary.load(std::memory_order_acquire)) {
            QCoreApplication::processEvents();
            msleep(1);
        }
    }

private:
    QString m_runtimeDirectory;
    std::atomic<bool> &m_start;
    std::atomic<bool> &m_releasePrimary;
    std::atomic<int> &m_completed;
};
}

class ActivationTest final : public QObject {
    Q_OBJECT

private slots:
    void launchArgumentsPreserveExactMailtoBytes();
    void launchArgumentsRejectAmbiguityAndOversize();
    void resourceAndSmokeArgumentsRemainDistinct();
    void coldLaunchCreatesPrivatePrimaryEndpoint();
    void warmLaunchHandsOffExactPayloadBeforeSecondaryExits();
    void backgroundHandoffDoesNotRaisePrimary();
    void activationIsQueuedUntilQmlIsReady();
    void pendingActivationOverflowIsRejectedWithoutLoss();
    void initializationFailureRejectsPendingActivations();
    void fileOpenEventsUseTheSameActivationPath();
    void fileOpenEventsDocumentUrlNormalization();
    void splitFramesDoNotSplitUrlText();
    void malformedAndOversizedFramesAreRejected();
    void unresponsivePrimaryPreventsDuplicateLaunch();
    void staleSocketIsRecovered();
    void concurrentStaleRecoveryHasExactlyOnePrimary();
    void unsafeRuntimeLinkIsRefused();
    void statusPublishesOnlySanitizedFieldsAndShutdown();
    void statusReplacementIsAtomicForReaders();
    void statusSymlinkIsRefusedWithoutChangingTarget();
    void publicStatusFileIsRefused();
};

void ActivationTest::launchArgumentsPreserveExactMailtoBytes()
{
    QCOMPARE(parseLaunchArguments({}).activationPayload, QStringLiteral("{}"));
    QCOMPARE(parseLaunchArguments({QByteArrayLiteral("--background")}).action,
             LaunchOptions::Action::Background);
    QCOMPARE(parseLaunchArguments({QByteArrayLiteral("--compose")}).activationPayload,
             QStringLiteral("{\"compose\":true}"));

    const QByteArray url = QByteArrayLiteral(
        "MAILTO:one+tag@example.test?subject=A+B%20C%2bD&body=100%25+%2B%0Aline%20two"
        "&x=%2f%3d%26&raw=line\nnext");
    const LaunchOptions options = parseLaunchArguments({url});
    QVERIFY2(options.ok, qPrintable(options.error));
    QCOMPARE(options.action, LaunchOptions::Action::Mailto);
    const QJsonObject payload = QJsonDocument::fromJson(
        options.activationPayload.toUtf8()).object();
    QCOMPARE(payload.value(QStringLiteral("mailto")).toString().toUtf8(), url);
    QVERIFY(validActivationPayload(options.activationPayload));
}

void ActivationTest::launchArgumentsRejectAmbiguityAndOversize()
{
    QVERIFY(!parseLaunchArguments({QByteArrayLiteral("--unknown")}).ok);
    QVERIFY(!parseLaunchArguments({QByteArrayLiteral("--background"),
                                   QByteArrayLiteral("--compose")}).ok);
    QVERIFY(!parseLaunchArguments({QByteArrayLiteral("mailto:a@example.test"),
                                   QByteArrayLiteral("mailto:b@example.test")}).ok);
    QVERIFY(!parseLaunchArguments({QByteArrayLiteral("https://example.test")}).ok);
    QVERIFY(!parseLaunchArguments({QByteArrayLiteral("--background"), QByteArray()}).ok);
    QVERIFY(!parseLaunchArguments({QByteArrayLiteral("mailto:") + QByteArray(17000, 'x')}).ok);
    const QByteArray invalidUtf8 = QByteArrayLiteral("mailto:") + QByteArray(1, '\xff');
    QVERIFY(!parseLaunchArguments({invalidUtf8}).ok);
    QVERIFY(!validActivationPayload(QStringLiteral("{\"compose\":true,\"extra\":1}")));
    QVERIFY(!validActivationPayload(QStringLiteral("{\"background\":true}")));
    QVERIFY(validActivationPayload(QStringLiteral("{\"background\":true}"), true));
}

void ActivationTest::resourceAndSmokeArgumentsRemainDistinct()
{
    QCOMPARE(parseLaunchArguments({QByteArrayLiteral("--check-resources")}).action,
             LaunchOptions::Action::CheckResources);
    const LaunchOptions smoke = parseLaunchArguments(
        {QByteArrayLiteral("--smoke-test"), QByteArrayLiteral("/private/ready file.json")});
    QVERIFY(smoke.ok);
    QCOMPARE(smoke.action, LaunchOptions::Action::SmokeTest);
    QCOMPARE(smoke.smokeReadyFile, QStringLiteral("/private/ready file.json"));
    QVERIFY(!parseLaunchArguments({QByteArrayLiteral("--smoke-test")}).ok);
}

void ActivationTest::coldLaunchCreatesPrivatePrimaryEndpoint()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    ActivationChannel channel(runtimePath(directory));
    ActivationChannel::Role role;
    QString error;
    QVERIFY2(channel.acquire(QStringLiteral("{}"), &role, &error), qPrintable(error));
    QCOMPARE(role, ActivationChannel::Role::Primary);
    QVERIFY(channel.isListening());
    const QFileInfo runtime(runtimePath(directory));
    const QFileInfo endpoint(channel.socketPath());
    const auto unsafe = QFileDevice::ReadGroup | QFileDevice::WriteGroup
        | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::WriteOther
        | QFileDevice::ExeOther;
    QVERIFY(!(runtime.permissions() & unsafe));
    QVERIFY(!(endpoint.permissions() & unsafe));
}

void ActivationTest::warmLaunchHandsOffExactPayloadBeforeSecondaryExits()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));
    QSignalSpy activated(&primary, &ActivationChannel::activationRequested);

    const QByteArray url = QByteArrayLiteral(
        "mailto:one+tag@example.test?subject=%2B+%20%26&body=first%0Asecond&x=100%");
    const LaunchOptions launch = parseLaunchArguments({url});
    ActivationChannel secondary(runtimePath(directory));
    QVERIFY2(secondary.acquire(launch.activationPayload, &role, &error), qPrintable(error));
    QCOMPARE(role, ActivationChannel::Role::Secondary);
    QVERIFY(!secondary.isListening());
    QTRY_COMPARE(activated.size(), 1);
    const QJsonObject received = QJsonDocument::fromJson(
        activated.constFirst().constFirst().toString().toUtf8()).object();
    QCOMPARE(received.value(QStringLiteral("mailto")).toString().toUtf8(), url);
}

void ActivationTest::backgroundHandoffDoesNotRaisePrimary()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    primary.suspendDelivery();
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));
    QSignalSpy activated(&primary, &ActivationChannel::activationRequested);
    ActivationChannel secondary(runtimePath(directory));
    QVERIFY(secondary.acquire(QStringLiteral("{\"background\":true}"),
                              &role, &error));
    QCOMPARE(role, ActivationChannel::Role::Secondary);
    QTest::qWait(20);
    QCOMPARE(activated.size(), 0);
}

void ActivationTest::activationIsQueuedUntilQmlIsReady()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));
    ActivationChannel secondary(runtimePath(directory));
    QVERIFY(secondary.acquire(QStringLiteral("{\"compose\":true}"), &role, &error));
    QCOMPARE(primary.takePendingActivations(),
             (QStringList() << QStringLiteral("{\"compose\":true}")));
    QVERIFY(primary.takePendingActivations().isEmpty());
}

void ActivationTest::pendingActivationOverflowIsRejectedWithoutLoss()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    primary.suspendDelivery();
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));

    constexpr int requestCount = 17;
    QList<QByteArray> payloads;
    std::vector<std::unique_ptr<QLocalSocket>> sockets;
    for (int index = 0; index < requestCount; ++index) {
        const QByteArray payload = QJsonDocument(QJsonObject{
            {QStringLiteral("mailto"), QStringLiteral("mailto:%1@example.test").arg(index)}})
            .toJson(QJsonDocument::Compact);
        payloads.append(payload);
        auto socket = std::make_unique<QLocalSocket>();
        socket->connectToServer(primary.socketPath());
        QVERIFY(socket->waitForConnected(1000));
        QCOMPARE(socket->write(testFrame(payload)), qint64(sizeof(quint32) + payload.size()));
        QVERIFY(socket->waitForBytesWritten(1000));
        sockets.push_back(std::move(socket));
    }

    QTRY_VERIFY([&sockets] {
        for (const auto &socket : sockets) {
            if (socket->bytesAvailable() > 0) return true;
        }
        return false;
    }());
    int rejected = -1;
    for (int index = 0; index < requestCount; ++index) {
        if (sockets[index]->bytesAvailable() == 0) continue;
        bool accepted = true;
        QVERIFY(readAcknowledgement(*sockets[index], &accepted));
        QVERIFY(!accepted);
        QCOMPARE(rejected, -1);
        rejected = index;
    }
    QVERIFY(rejected >= 0);

    QSignalSpy activated(&primary, &ActivationChannel::activationRequested);
    QVERIFY(primary.enableDelivery());
    QTRY_COMPARE(activated.size(), requestCount - 1);
    QStringList delivered;
    for (const QList<QVariant> &arguments : activated)
        delivered.append(arguments.constFirst().toString());
    QStringList expected;
    for (int index = 0; index < requestCount; ++index) {
        if (index == rejected) continue;
        expected.append(QString::fromUtf8(payloads[index]));
        QVERIFY(acknowledged(*sockets[index]));
    }
    delivered.sort();
    expected.sort();
    QCOMPARE(delivered, expected);
    QVERIFY(primary.takePendingActivations().isEmpty());
}

void ActivationTest::initializationFailureRejectsPendingActivations()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    primary.suspendDelivery();
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));

    std::vector<std::unique_ptr<QLocalSocket>> sockets;
    for (int index = 0; index < 17; ++index) {
        const QByteArray payload = QJsonDocument(QJsonObject{
            {QStringLiteral("mailto"), QStringLiteral("mailto:%1@example.test").arg(index)}})
            .toJson(QJsonDocument::Compact);
        auto socket = std::make_unique<QLocalSocket>();
        socket->connectToServer(primary.socketPath());
        QVERIFY(socket->waitForConnected(1000));
        QCOMPARE(socket->write(testFrame(payload)), qint64(sizeof(quint32) + payload.size()));
        QVERIFY(socket->waitForBytesWritten(1000));
        sockets.push_back(std::move(socket));
    }
    QTRY_VERIFY([&sockets] {
        for (const auto &socket : sockets) {
            if (socket->bytesAvailable() > 0) return true;
        }
        return false;
    }());
    // The seventeenth request's overflow rejection proves the other sixteen were buffered.
    primary.rejectPendingActivations();
    for (const auto &socket : sockets) {
        bool accepted = true;
        QVERIFY2(readAcknowledgement(*socket, &accepted),
                 "Initialization failure must produce a negative acknowledgement, not a timeout");
        QVERIFY(!accepted);
        QVERIFY(socket->state() == QLocalSocket::UnconnectedState
                || socket->waitForDisconnected(1000));
    }
    QVERIFY(primary.takePendingActivations().isEmpty());
}

void ActivationTest::fileOpenEventsUseTheSameActivationPath()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));
    QSignalSpy activated(&primary, &ActivationChannel::activationRequested);
    auto *application = QCoreApplication::instance();
    application->installEventFilter(&primary);
    QFileOpenEvent mailto(QUrl(QStringLiteral(
        "mailto:one+tag@example.test?subject=A%2BB&body=line%0Atwo")));
    QVERIFY(QCoreApplication::sendEvent(application, &mailto));
    QCOMPARE(activated.size(), 1);
    const QJsonObject payload = QJsonDocument::fromJson(
        activated.constFirst().constFirst().toString().toUtf8()).object();
    QCOMPARE(payload.value(QStringLiteral("mailto")).toString(),
             QStringLiteral("mailto:one+tag@example.test?subject=A%2BB&body=line%0Atwo"));
    QFileOpenEvent http(QUrl(QStringLiteral("https://example.test")));
    QVERIFY(!QCoreApplication::sendEvent(application, &http));
    QCOMPARE(activated.size(), 1);
    application->removeEventFilter(&primary);
}

void ActivationTest::fileOpenEventsDocumentUrlNormalization()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    QSignalSpy activated(&primary, &ActivationChannel::activationRequested);
    auto *application = QCoreApplication::instance();
    application->installEventFilter(&primary);
    QFileOpenEvent mailto(QUrl::fromEncoded(QByteArrayLiteral(
        "MAILTO:%C3%A9@example.test?subject=%c3%a9&body=100%25%0Anext&x=%2b%2f")));
    QVERIFY(QCoreApplication::sendEvent(application, &mailto));
    QCOMPARE(activated.size(), 1);
    const QJsonObject payload = QJsonDocument::fromJson(
        activated.constFirst().constFirst().toString().toUtf8()).object();
    QCOMPARE(payload.value(QStringLiteral("mailto")).toString(), QStringLiteral(
        "mailto:%C3%A9@example.test?subject=%C3%A9&body=100%25%0Anext&x=%2B%2F"));

    QFileOpenEvent escapes(QUrl(QStringLiteral("mailto:a@example.test?body=100%\nnext")));
    QVERIFY(QCoreApplication::sendEvent(application, &escapes));
    application->removeEventFilter(&primary);
    QCOMPARE(activated.size(), 2);
    const QJsonObject escapedPayload = QJsonDocument::fromJson(
        activated.at(1).constFirst().toString().toUtf8()).object();
    QCOMPARE(escapedPayload.value(QStringLiteral("mailto")).toString(),
             QStringLiteral("mailto:a@example.test?body=100%25%0Anext"));
}

void ActivationTest::splitFramesDoNotSplitUrlText()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));
    QSignalSpy activated(&primary, &ActivationChannel::activationRequested);
    const QByteArray url = QByteArrayLiteral("mailto:a@example.test?body=one\ntwo%0Athree");
    const QByteArray payload = QJsonDocument(QJsonObject{
        {QStringLiteral("mailto"), QString::fromUtf8(url)}}).toJson(QJsonDocument::Compact);
    const QByteArray frame = testFrame(payload);
    QLocalSocket socket;
    socket.connectToServer(primary.socketPath());
    QVERIFY(socket.waitForConnected(1000));
    QCOMPARE(socket.write(frame.left(2)), 2);
    QVERIFY(socket.waitForBytesWritten(1000));
    QTest::qWait(10);
    QCOMPARE(activated.size(), 0);
    QCOMPARE(socket.write(frame.mid(2, 7)), 7);
    QVERIFY(socket.waitForBytesWritten(1000));
    QCOMPARE(socket.write(frame.mid(9)), qint64(frame.size() - 9));
    QVERIFY(acknowledged(socket));
    QTRY_COMPARE(activated.size(), 1);
    const QJsonObject received = QJsonDocument::fromJson(
        activated.constFirst().constFirst().toString().toUtf8()).object();
    QCOMPARE(received.value(QStringLiteral("mailto")).toString().toUtf8(), url);
}

void ActivationTest::malformedAndOversizedFramesAreRejected()
{
    QTemporaryDir directory;
    ActivationChannel primary(runtimePath(directory));
    ActivationChannel::Role role;
    QString error;
    QVERIFY(primary.acquire(QStringLiteral("{}"), &role, &error));
    QSignalSpy activated(&primary, &ActivationChannel::activationRequested);

    QLocalSocket malformed;
    malformed.connectToServer(primary.socketPath());
    QVERIFY(malformed.waitForConnected(1000));
    QCOMPARE(malformed.write(testFrame(QByteArrayLiteral("{not-json"))),
             qint64(sizeof(quint32) + 9));
    bool malformedAccepted = true;
    QVERIFY2(readAcknowledgement(malformed, &malformedAccepted),
             "Malformed input must receive a prompt negative acknowledgement");
    QVERIFY(!malformedAccepted);
    QVERIFY(malformed.state() == QLocalSocket::UnconnectedState
            || malformed.waitForDisconnected(1000));

    QLocalSocket oversized;
    oversized.connectToServer(primary.socketPath());
    QVERIFY(oversized.waitForConnected(1000));
    QByteArray prefix(sizeof(quint32), Qt::Uninitialized);
    qToBigEndian(maximumActivationPayloadBytes + 1,
                 reinterpret_cast<uchar *>(prefix.data()));
    QCOMPARE(oversized.write(prefix), qint64(sizeof(quint32)));
    bool oversizedAccepted = true;
    QVERIFY2(readAcknowledgement(oversized, &oversizedAccepted),
             "Oversized input must receive a prompt negative acknowledgement");
    QVERIFY(!oversizedAccepted);
    QVERIFY(oversized.state() == QLocalSocket::UnconnectedState
            || oversized.waitForDisconnected(1000));
    QCOMPARE(activated.size(), 0);
}

void ActivationTest::unresponsivePrimaryPreventsDuplicateLaunch()
{
    QTemporaryDir directory;
    QString error;
    QVERIFY(ensureRuntimeDirectory(runtimePath(directory), &error));
    QLocalServer unresponsive;
    unresponsive.setSocketOptions(QLocalServer::UserAccessOption);
    QVERIFY(unresponsive.listen(QDir(runtimePath(directory)).filePath(
        QStringLiteral("activation.sock"))));
    ActivationChannel second(runtimePath(directory));
    ActivationChannel::Role role = ActivationChannel::Role::Primary;
    QVERIFY(!second.acquire(QStringLiteral("{}"), &role, &error, 50));
    QVERIFY(error.contains(QStringLiteral("acknowledge")));
    QVERIFY(!second.isListening());
    QVERIFY(unresponsive.isListening());
}

void ActivationTest::staleSocketIsRecovered()
{
#ifdef Q_OS_UNIX
    QTemporaryDir directory;
    QString error;
    QVERIFY(ensureRuntimeDirectory(runtimePath(directory), &error));
    const QString path = QDir(runtimePath(directory)).filePath(
        QStringLiteral("activation.sock"));
    const QByteArray native = QFile::encodeName(path);
    const int descriptor = ::socket(AF_UNIX, SOCK_STREAM, 0);
    QVERIFY(descriptor >= 0);
    sockaddr_un address {};
    address.sun_family = AF_UNIX;
    QVERIFY(static_cast<size_t>(native.size()) < sizeof(address.sun_path));
    std::memcpy(address.sun_path, native.constData(), native.size() + 1);
    QCOMPARE(::bind(descriptor, reinterpret_cast<sockaddr *>(&address), sizeof(address)), 0);
    ::close(descriptor);
    QVERIFY(QFileInfo::exists(path));

    ActivationChannel channel(runtimePath(directory));
    ActivationChannel::Role role;
    QVERIFY2(channel.acquire(QStringLiteral("{}"), &role, &error), qPrintable(error));
    QCOMPARE(role, ActivationChannel::Role::Primary);
#else
    QSKIP("Unix stale socket fixture");
#endif
}

void ActivationTest::concurrentStaleRecoveryHasExactlyOnePrimary()
{
#ifdef Q_OS_UNIX
    constexpr int launcherCount = 4;
    for (int round = 0; round < 6; ++round) {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        QString error;
        QVERIFY(ensureRuntimeDirectory(runtimePath(directory), &error));
        const QString path = QDir(runtimePath(directory)).filePath(
            QStringLiteral("activation.sock"));
        const QByteArray native = QFile::encodeName(path);
        const int descriptor = ::socket(AF_UNIX, SOCK_STREAM, 0);
        QVERIFY(descriptor >= 0);
        sockaddr_un address {};
        address.sun_family = AF_UNIX;
        QVERIFY(static_cast<size_t>(native.size()) < sizeof(address.sun_path));
        std::memcpy(address.sun_path, native.constData(), native.size() + 1);
        QCOMPARE(::bind(descriptor, reinterpret_cast<sockaddr *>(&address), sizeof(address)), 0);
        ::close(descriptor);
        QVERIFY(QFileInfo::exists(path));

        std::atomic<bool> start = false;
        std::atomic<bool> releasePrimary = false;
        std::atomic<int> completed = 0;
        std::vector<std::unique_ptr<ConcurrentLauncher>> launchers;
        for (int index = 0; index < launcherCount; ++index) {
            auto launcher = std::make_unique<ConcurrentLauncher>(
                runtimePath(directory), start, releasePrimary, completed);
            launcher->start();
            launchers.push_back(std::move(launcher));
        }
        start.store(true, std::memory_order_release);
        QDeadlineTimer deadline(15000);
        while (completed.load(std::memory_order_acquire) < launcherCount
               && !deadline.hasExpired()) {
            QCoreApplication::processEvents();
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        const bool allCompleted = completed.load(std::memory_order_acquire) == launcherCount;
        releasePrimary.store(true, std::memory_order_release);
        for (const auto &launcher : launchers) QVERIFY(launcher->wait(2000));
        QVERIFY2(allCompleted, "Concurrent launchers did not finish their acquire calls");

        int primaryCount = 0;
        int secondaryCount = 0;
        for (const auto &launcher : launchers) {
            QVERIFY2(launcher->acquired, qPrintable(launcher->error));
            if (launcher->role == ActivationChannel::Role::Primary) ++primaryCount;
            else ++secondaryCount;
        }
        QCOMPARE(primaryCount, 1);
        QCOMPARE(secondaryCount, launcherCount - 1);
    }
#else
    QSKIP("Unix stale socket fixture");
#endif
}

void ActivationTest::unsafeRuntimeLinkIsRefused()
{
#ifdef Q_OS_UNIX
    QTemporaryDir directory;
    const QString target = directory.filePath(QStringLiteral("target"));
    QVERIFY(QDir().mkdir(target));
    const QString link = directory.filePath(QStringLiteral("magpie-mail"));
    QVERIFY(QFile::link(target, link));
    ActivationChannel channel(link);
    ActivationChannel::Role role;
    QString error;
    QVERIFY(!channel.acquire(QStringLiteral("{}"), &role, &error));
    QVERIFY(error.contains(QStringLiteral("unsafe")));
    QVERIFY(!channel.isListening());
#else
    QSKIP("Unix symlink fixture");
#endif
}

void ActivationTest::statusPublishesOnlySanitizedFieldsAndShutdown()
{
    QTemporaryDir directory;
    QFile manifest(directory.filePath(QStringLiteral("manifest.json")));
    QVERIFY(manifest.open(QIODevice::WriteOnly));
    QCOMPARE(manifest.write("{}"), 2);
    manifest.close();
    ApplicationHost host(manifest.fileName(), {},
                         directory.filePath(QStringLiteral("settings.json")));
    QString error;
    QVERIFY2(host.configureStatusWriter(runtimePath(directory), &error), qPrintable(error));
    const qint64 before = QDateTime::currentMSecsSinceEpoch();
    QVERIFY(host.updateBarStatus({
        {QStringLiteral("ready"), true}, {QStringLiteral("windowOpen"), true},
        {QStringLiteral("showBarIcon"), false}, {QStringLiteral("unreadTotal"), 7.9},
        {QStringLiteral("accountId"), QStringLiteral("private-account@example.test")},
        {QStringLiteral("subject"), QStringLiteral("private message")},
        {QStringLiteral("token"), QStringLiteral("private-token")}}));
    const qint64 after = QDateTime::currentMSecsSinceEpoch();
    StatusFile status(runtimePath(directory));
    QFile file(status.path());
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QByteArray bytes = file.readAll();
    QVERIFY(!bytes.contains("private-account"));
    QVERIFY(!bytes.contains("private message"));
    QVERIFY(!bytes.contains("private-token"));
    const QJsonObject object = QJsonDocument::fromJson(bytes).object();
    QCOMPARE(object.keys().size(), 5);
    QCOMPARE(object.value(QStringLiteral("ready")).toBool(), true);
    QCOMPARE(object.value(QStringLiteral("windowOpen")).toBool(), true);
    QCOMPARE(object.value(QStringLiteral("showBarIcon")).toBool(), false);
    QCOMPARE(object.value(QStringLiteral("unreadTotal")).toInt(), 7);
    QVERIFY(object.value(QStringLiteral("updated")).toDouble() >= before);
    QVERIFY(object.value(QStringLiteral("updated")).toDouble() <= after);
#ifndef Q_OS_WIN
    const auto unsafe = QFileDevice::ReadGroup | QFileDevice::WriteGroup
        | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::WriteOther
        | QFileDevice::ExeOther;
    QVERIFY(!(QFileInfo(status.path()).permissions() & unsafe));
#endif

    QVERIFY(host.updateBarStatus({{QStringLiteral("unreadTotal"),
                                   QStringLiteral("not-a-number")}}));
    QCOMPARE(statusAt(status.path()).value(QStringLiteral("unreadTotal")).toInt(), 0);
    host.quit();
    const QJsonObject stopped = statusAt(status.path());
    QCOMPARE(stopped.value(QStringLiteral("ready")).toBool(), false);
    QCOMPARE(stopped.value(QStringLiteral("windowOpen")).toBool(), false);
    QVERIFY(!host.updateBarStatus({{QStringLiteral("ready"), true}}));
}

void ActivationTest::statusReplacementIsAtomicForReaders()
{
    QTemporaryDir directory;
    StatusFile writer(runtimePath(directory));
    QString error;
    BarStatus initial;
    initial.ready = true;
    initial.unreadTotal = 2;
    QVERIFY(writer.write(initial, &error));
    std::atomic<bool> stop = false;
    std::atomic<bool> invalid = false;
    std::thread reader([&] {
        while (!stop.load()) {
            QFile file(writer.path());
            if (!file.open(QIODevice::ReadOnly)) {
                invalid = true;
                continue;
            }
            const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
            const QJsonObject object = document.object();
            if (!document.isObject() || object.size() != 5
                || object.value(QStringLiteral("ready")).toBool()
                    != (object.value(QStringLiteral("unreadTotal")).toInt() % 2 == 0))
                invalid = true;
        }
    });
    for (int index = 0; index < 120; ++index) {
        BarStatus next;
        next.ready = index % 2 == 0;
        next.unreadTotal = index;
        QVERIFY(writer.write(next, &error));
    }
    stop = true;
    reader.join();
    QVERIFY(!invalid.load());
    const QJsonObject final = statusAt(writer.path());
    QCOMPARE(final.value(QStringLiteral("unreadTotal")).toInt(), 119);
}

void ActivationTest::statusSymlinkIsRefusedWithoutChangingTarget()
{
#ifdef Q_OS_UNIX
    QTemporaryDir directory;
    QString error;
    QVERIFY(ensureRuntimeDirectory(runtimePath(directory), &error));
    const QString outside = directory.filePath(QStringLiteral("outside.json"));
    QFile target(outside);
    QVERIFY(target.open(QIODevice::WriteOnly));
    QCOMPARE(target.write("unchanged"), 9);
    target.close();
    const QString path = QDir(runtimePath(directory)).filePath(QStringLiteral("status.json"));
    QVERIFY(QFile::link(outside, path));
    StatusFile status(runtimePath(directory));
    QVERIFY(!status.write(BarStatus{}, &error));
    QVERIFY(error.contains(QStringLiteral("unsafe")));
    QVERIFY(target.open(QIODevice::ReadOnly));
    QCOMPARE(target.readAll(), QByteArray("unchanged"));
#else
    QSKIP("Unix symlink fixture");
#endif
}

void ActivationTest::publicStatusFileIsRefused()
{
#ifdef Q_OS_UNIX
    QTemporaryDir directory;
    StatusFile status(runtimePath(directory));
    QString error;
    QVERIFY(status.write(BarStatus{}, &error));
    QFile file(status.path());
    QVERIFY(file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                | QFileDevice::ReadGroup | QFileDevice::ReadOther));
    QVERIFY(!status.write(BarStatus{}, &error));
    QVERIFY(error.contains(QStringLiteral("not private")));
#else
    QSKIP("Unix permission fixture");
#endif
}

QTEST_MAIN(ActivationTest)
#include "tst_activation.moc"
