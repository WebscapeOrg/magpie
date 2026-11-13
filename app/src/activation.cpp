#include "activation.h"
#include "runtime.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFileOpenEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QLocalSocket>
#include <QLockFile>
#include <QMetaMethod>
#include <QTimer>
#include <QUrl>
#include <QtEndian>

#include <cstring>

#ifndef Q_OS_WIN
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace {
constexpr int maximumPendingActivations = 16;
constexpr int maximumAcknowledgementBytes = 128;
constexpr int connectionLifetimeMilliseconds = 2000;
const QByteArray openPayload = QByteArrayLiteral("{}");

void setError(QString *error, const QString &message)
{
    if (error) *error = message;
}

QByteArray encodeFrame(const QJsonObject &object)
{
    const QByteArray payload = QJsonDocument(object).toJson(QJsonDocument::Compact);
    if (payload.isEmpty() || static_cast<quint32>(payload.size())
            > maximumActivationPayloadBytes) return {};
    QByteArray frame(sizeof(quint32), Qt::Uninitialized);
    qToBigEndian(static_cast<quint32>(payload.size()),
                 reinterpret_cast<uchar *>(frame.data()));
    frame.append(payload);
    return frame;
}

QByteArray encodePayload(const QString &payload)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(payload.toUtf8(), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) return {};
    return encodeFrame(document.object());
}

QString mailtoPayload(const QByteArray &url)
{
    if (url.isEmpty() || url.size() > maximumMailtoUrlBytes
        || !url.left(7).toLower().startsWith("mailto:")) return {};
    const QString decoded = QString::fromUtf8(url);
    if (decoded.toUtf8() != url) return {};
    return QString::fromUtf8(QJsonDocument(QJsonObject{
        {QStringLiteral("mailto"), decoded}}).toJson(QJsonDocument::Compact));
}

LaunchOptions launchSuccess(LaunchOptions::Action action, QString payload = {})
{
    LaunchOptions options;
    options.ok = true;
    options.action = action;
    options.activationPayload = std::move(payload);
    return options;
}

LaunchOptions launchFailure(const QString &error)
{
    LaunchOptions options;
    options.error = error;
    return options;
}

bool unavailableSocketError(QLocalSocket::LocalSocketError error)
{
    return error == QLocalSocket::ServerNotFoundError
        || error == QLocalSocket::ConnectionRefusedError;
}

bool secureAcquisitionLock(const QLockFile &lock, QString *error)
{
    const QString path = lock.fileName();
    QFile file(path);
    if (!file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner)) {
        setError(error, QStringLiteral("Could not protect the activation acquisition lock"));
        return false;
    }
    const QFileInfo info(path);
    if (!info.exists() || info.isSymLink() || !info.isFile()) {
        setError(error, QStringLiteral("Activation acquisition lock is not a regular file"));
        return false;
    }
#ifndef Q_OS_WIN
    const auto unsafe = QFileDevice::ReadGroup | QFileDevice::WriteGroup
        | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::WriteOther
        | QFileDevice::ExeOther;
    struct stat details {};
    const QByteArray native = QFile::encodeName(path);
    if (info.ownerId() != static_cast<uint>(geteuid()) || (info.permissions() & unsafe)
        || ::lstat(native.constData(), &details) != 0 || !S_ISREG(details.st_mode)
        || details.st_uid != geteuid() || details.st_nlink != 1) {
        setError(error, QStringLiteral("Activation acquisition lock is not private"));
        return false;
    }
#endif
    return true;
}
}

LaunchOptions parseLaunchArguments(const QList<QByteArray> &arguments)
{
    if (arguments.isEmpty()) return launchSuccess(LaunchOptions::Action::Open, openPayload);
    if (arguments.size() == 1 && arguments.constFirst() == QByteArrayLiteral("--background"))
        return launchSuccess(LaunchOptions::Action::Background,
                             QByteArrayLiteral("{\"background\":true}"));
    if (arguments.size() == 1 && arguments.constFirst() == QByteArrayLiteral("--compose"))
        return launchSuccess(LaunchOptions::Action::Compose,
                             QByteArrayLiteral("{\"compose\":true}"));
    if (arguments.size() == 1
        && arguments.constFirst() == QByteArrayLiteral("--check-resources"))
        return launchSuccess(LaunchOptions::Action::CheckResources);
    if (arguments.size() == 2 && arguments.constFirst() == QByteArrayLiteral("--smoke-test")
        && !arguments.at(1).isEmpty() && arguments.at(1).size() <= 4096) {
        LaunchOptions options = launchSuccess(LaunchOptions::Action::SmokeTest);
        options.smokeReadyFile = QString::fromLocal8Bit(arguments.at(1));
        return options;
    }
    if (arguments.size() == 1) {
        const QString payload = mailtoPayload(arguments.constFirst());
        if (!payload.isEmpty())
            return launchSuccess(LaunchOptions::Action::Mailto, payload);
    }
    return launchFailure(QStringLiteral(
        "Usage: omamail-app [--background | --compose | mailto:URL | "
        "--check-resources | --smoke-test READY-FILE]"));
}

bool validActivationPayload(const QString &payload, bool allowBackground)
{
    const QByteArray bytes = payload.toUtf8();
    if (bytes.isEmpty() || static_cast<quint32>(bytes.size())
            > maximumActivationPayloadBytes) return false;
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(bytes, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) return false;
    const QJsonObject object = document.object();
    if (object.isEmpty()) return true;
    if (object.size() != 1) return false;
    if (object.contains(QStringLiteral("compose")))
        return object.value(QStringLiteral("compose")).isBool()
            && object.value(QStringLiteral("compose")).toBool();
    if (object.contains(QStringLiteral("background")))
        return allowBackground && object.value(QStringLiteral("background")).isBool()
            && object.value(QStringLiteral("background")).toBool();
    if (!object.contains(QStringLiteral("mailto"))
        || !object.value(QStringLiteral("mailto")).isString()) return false;
    const QString url = object.value(QStringLiteral("mailto")).toString();
    const QByteArray rawUrl = url.toUtf8();
    return !rawUrl.isEmpty() && rawUrl.size() <= maximumMailtoUrlBytes
        && rawUrl.left(7).toLower().startsWith("mailto:");
}

ActivationChannel::ActivationChannel(QObject *parent)
    : ActivationChannel(defaultRuntimeDirectory(), parent)
{
}

ActivationChannel::ActivationChannel(QString runtimeDirectory, QObject *parent)
    : QObject(parent), m_runtimeDirectory(std::move(runtimeDirectory))
{
    connect(&m_server, &QLocalServer::newConnection, this,
            &ActivationChannel::acceptConnections);
}

ActivationChannel::~ActivationChannel()
{
    rejectPendingActivations();
    if (!m_server.isListening()) return;
    const QString lockPath = QDir(m_runtimeDirectory).filePath(
        QStringLiteral("activation.lock"));
    QLockFile cleanupLock(lockPath);
    cleanupLock.setStaleLockTime(30000);
    if (!cleanupLock.tryLock(connectionLifetimeMilliseconds)) {
        qWarning().noquote()
            << "Could not lock activation socket cleanup; leaving its endpoint in place"
            << lockPath;
        m_server.close();
        return;
    }
    QString lockError;
    if (!secureAcquisitionLock(cleanupLock, &lockError)) {
        qWarning().noquote() << lockError << lockPath;
        m_server.close();
        return;
    }
    m_server.close();
    QString ignored;
    removeStaleSocket(&ignored);
}

QString ActivationChannel::socketPath() const
{
    return QDir(m_runtimeDirectory).filePath(QStringLiteral("activation.sock"));
}

void ActivationChannel::suspendDelivery()
{
    m_deliverySuspended = true;
}

bool ActivationChannel::enableDelivery()
{
    m_deliverySuspended = false;
    if (!isSignalConnected(QMetaMethod::fromSignal(
            &ActivationChannel::activationRequested))) {
        qWarning() << "Cannot enable activation delivery without a QML consumer";
        rejectPendingActivations();
        return false;
    }
    const QList<PendingActivation> pending = std::move(m_pendingActivations);
    m_pendingActivations.clear();
    for (const PendingActivation &activation : pending) {
        emit activationRequested(activation.payload);
        if (activation.socket) acknowledgeConnection(activation.socket);
    }
    return true;
}

void ActivationChannel::rejectPendingActivations()
{
    m_deliveryFailed = true;
    const QList<PendingActivation> pending = std::move(m_pendingActivations);
    m_pendingActivations.clear();
    for (const PendingActivation &activation : pending) {
        if (activation.socket) rejectConnection(activation.socket);
    }
}

QStringList ActivationChannel::takePendingActivations()
{
    QStringList payloads;
    const QList<PendingActivation> pending = std::move(m_pendingActivations);
    m_pendingActivations.clear();
    payloads.reserve(pending.size());
    for (const PendingActivation &activation : pending) {
        payloads.append(activation.payload);
        if (activation.socket) acknowledgeConnection(activation.socket);
    }
    return payloads;
}

ActivationChannel::HandoffResult ActivationChannel::handOff(
    const QString &payload, QString *error, int timeoutMilliseconds) const
{
    if (!validActivationPayload(payload, true)) {
        setError(error, QStringLiteral("Activation payload is invalid"));
        return HandoffResult::Failed;
    }
    const QByteArray frame = encodePayload(payload);
    if (frame.isEmpty()) {
        setError(error, QStringLiteral("Activation payload is too large"));
        return HandoffResult::Failed;
    }
    QDeadlineTimer deadline(qMax(1, timeoutMilliseconds));
    QLocalSocket socket;
    socket.connectToServer(socketPath());
    if (!socket.waitForConnected(qMax(1, static_cast<int>(deadline.remainingTime())))) {
        if (unavailableSocketError(socket.error())) {
            if (error) error->clear();
            return HandoffResult::Unavailable;
        }
        setError(error, QStringLiteral("Could not connect to the running Magpie Mail app"));
        return HandoffResult::Failed;
    }
    if (socket.write(frame) != frame.size()
        || !socket.waitForBytesWritten(qMax(1, static_cast<int>(deadline.remainingTime())))) {
        setError(error, QStringLiteral("Could not send activation to the running app"));
        return HandoffResult::Failed;
    }

    QByteArray response;
    while (!deadline.hasExpired()) {
        const int waitSlice = static_cast<int>(qMin<qint64>(10, deadline.remainingTime()));
        if (socket.bytesAvailable() == 0
            && !socket.waitForReadyRead(qMax(1, waitSlice))) {
            QCoreApplication::processEvents();
            continue;
        }
        response.append(socket.read(maximumAcknowledgementBytes + 1));
        if (response.size() > maximumAcknowledgementBytes || socket.bytesAvailable() > 0) {
            setError(error, QStringLiteral("Running app returned an oversized acknowledgement"));
            return HandoffResult::Failed;
        }
        if (response.size() < static_cast<qsizetype>(sizeof(quint32))) continue;
        quint32 networkLength = 0;
        std::memcpy(&networkLength, response.constData(), sizeof(networkLength));
        const quint32 length = qFromBigEndian(networkLength);
        if (length == 0 || length > maximumAcknowledgementBytes - sizeof(quint32)) {
            setError(error, QStringLiteral("Running app returned an invalid acknowledgement"));
            return HandoffResult::Failed;
        }
        if (response.size() < static_cast<qsizetype>(sizeof(quint32) + length)) continue;
        if (response.size() > static_cast<qsizetype>(sizeof(quint32) + length)) {
            setError(error, QStringLiteral("Running app returned an invalid acknowledgement"));
            return HandoffResult::Failed;
        }
        const QJsonDocument document = QJsonDocument::fromJson(response.mid(sizeof(quint32)));
        const QJsonObject acknowledgement = document.object();
        if (!document.isObject() || acknowledgement.size() != 1
            || !acknowledgement.value(QStringLiteral("accepted")).isBool()) {
            setError(error, QStringLiteral("Running app returned an invalid acknowledgement"));
            return HandoffResult::Failed;
        }
        if (!acknowledgement.value(QStringLiteral("accepted")).toBool()) {
            setError(error, QStringLiteral("Running app rejected the activation payload"));
            return HandoffResult::Failed;
        }
        if (error) error->clear();
        return HandoffResult::Acknowledged;
    }
    setError(error, QStringLiteral("Running app did not acknowledge activation in time"));
    return HandoffResult::Failed;
}

bool ActivationChannel::removeStaleSocket(QString *error) const
{
    const QString path = socketPath();
    const QFileInfo info(path);
    if (!info.exists() && !info.isSymLink()) return true;
#ifndef Q_OS_WIN
    struct stat details {};
    const QByteArray native = QFile::encodeName(path);
    if (::lstat(native.constData(), &details) != 0 || !S_ISSOCK(details.st_mode)
        || details.st_uid != geteuid()) {
        setError(error, QStringLiteral("Refusing to replace an unsafe activation endpoint"));
        return false;
    }
    if (!QFile::remove(path)) {
        setError(error, QStringLiteral("Could not remove the stale activation socket"));
        return false;
    }
    return true;
#else
    if (info.isSymLink() || info.exists()) {
        setError(error, QStringLiteral("Refusing to replace an unsafe activation endpoint"));
        return false;
    }
    QLocalServer::removeServer(path);
    return true;
#endif
}

bool ActivationChannel::acquire(const QString &payload, Role *role, QString *error,
                                int timeoutMilliseconds)
{
    if (!validActivationPayload(payload, true)) {
        setError(error, QStringLiteral("Activation payload is invalid"));
        return false;
    }
    if (!ensureRuntimeDirectory(m_runtimeDirectory, error)) return false;
    QDeadlineTimer deadline(qMax(1, timeoutMilliseconds));
    const QString lockPath = QDir(m_runtimeDirectory).filePath(
        QStringLiteral("activation.lock"));
    QLockFile acquisitionLock(lockPath);
    acquisitionLock.setStaleLockTime(30000);
    if (!acquisitionLock.tryLock(qMax(1, static_cast<int>(deadline.remainingTime())))) {
        const QString message = QStringLiteral(
            "Could not acquire the activation acquisition lock");
        setError(error, message);
        qWarning().noquote() << message << lockPath;
        return false;
    }
    QString lockError;
    if (!secureAcquisitionLock(acquisitionLock, &lockError)) {
        setError(error, lockError);
        qWarning().noquote() << lockError << lockPath;
        return false;
    }

    // Invariant: One launcher at a time may probe, replace and bind the endpoint. The
    // lock remains held through the second handoff, so no stale recovery can unlink a
    // socket that another launcher has just made live.
    const HandoffResult first = handOff(payload, error,
        qMax(1, static_cast<int>(deadline.remainingTime())));
    if (first == HandoffResult::Acknowledged) {
        if (role) *role = Role::Secondary;
        return true;
    }
    if (first == HandoffResult::Failed) return false;
    if (!removeStaleSocket(error)) return false;

    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    if (m_server.listen(socketPath())) {
#ifndef Q_OS_WIN
        const QFileInfo endpoint(socketPath());
        const auto unsafe = QFileDevice::ReadGroup | QFileDevice::WriteGroup
            | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::WriteOther
            | QFileDevice::ExeOther;
        struct stat endpointDetails {};
        const QByteArray nativeEndpoint = QFile::encodeName(socketPath());
        if (::lstat(nativeEndpoint.constData(), &endpointDetails) != 0
            || !S_ISSOCK(endpointDetails.st_mode)
            || endpointDetails.st_uid != geteuid() || (endpoint.permissions() & unsafe)) {
            m_server.close();
            removeStaleSocket(error);
            setError(error, QStringLiteral("Activation socket is not user-only"));
            return false;
        }
#endif
        if (role) *role = Role::Primary;
        if (error) error->clear();
        return true;
    }

    // Invariant: Another launcher may have won the listen race. Join that primary rather
    // than removing its live socket or starting a second mail engine.
    const HandoffResult second = handOff(payload, error,
        qMax(1, static_cast<int>(deadline.remainingTime())));
    if (second == HandoffResult::Acknowledged) {
        if (role) *role = Role::Secondary;
        return true;
    }
    if (second == HandoffResult::Unavailable)
        setError(error, QStringLiteral("Could not create the activation socket: %1")
                         .arg(m_server.errorString()));
    return false;
}

bool ActivationChannel::eventFilter(QObject *watched, QEvent *event)
{
    if (event->type() != QEvent::FileOpen) return QObject::eventFilter(watched, event);
    const QUrl url = static_cast<QFileOpenEvent *>(event)->url();
    if (url.scheme().compare(QStringLiteral("mailto"), Qt::CaseInsensitive) != 0)
        return false;
    const QString payload = mailtoPayload(url.toString(QUrl::FullyEncoded).toUtf8());
    if (!payload.isEmpty()) deliverActivation(payload);
    return true;
}

void ActivationChannel::deliverActivation(const QString &payload, QLocalSocket *socket)
{
    if (m_deliveryFailed) {
        if (socket) rejectConnection(socket);
        return;
    }
    if (!m_deliverySuspended && isSignalConnected(QMetaMethod::fromSignal(
            &ActivationChannel::activationRequested))) {
        emit activationRequested(payload);
        if (socket) acknowledgeConnection(socket);
        return;
    }
    if (m_pendingActivations.size() >= maximumPendingActivations) {
        qWarning() << "Rejecting activation because its bounded pending queue is full";
        if (socket) rejectConnection(socket);
        return;
    }
    m_pendingActivations.append(PendingActivation{payload, socket});
    if (!socket) return;
    if (m_deliverySuspended) {
        socket->setProperty("activationBuffered", true);
        return;
    }
    // Unit-level users are ready by default and may explicitly take this queue later.
    // Production suspends delivery before acquire, so its acknowledgement follows QML.
    acknowledgeConnection(socket);
}

void ActivationChannel::acceptConnections()
{
    while (QLocalSocket *socket = m_server.nextPendingConnection()) {
        socket->setProperty("activationBuffer", QByteArray{});
        connect(socket, &QLocalSocket::readyRead, this,
                [this, socket] { readConnection(socket); });
        connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
        QTimer::singleShot(connectionLifetimeMilliseconds, socket, [socket] {
            if (!socket->property("activationComplete").toBool()
                && !socket->property("activationBuffered").toBool()) socket->abort();
        });
        readConnection(socket);
    }
}

void ActivationChannel::acknowledgeConnection(QLocalSocket *socket)
{
    if (socket->property("activationComplete").toBool()) return;
    socket->setProperty("activationComplete", true);
    socket->write(encodeFrame(QJsonObject{{QStringLiteral("accepted"), true}}));
    socket->disconnectFromServer();
}

void ActivationChannel::rejectConnection(QLocalSocket *socket)
{
    if (socket->property("activationComplete").toBool()) return;
    socket->setProperty("activationComplete", true);
    socket->write(encodeFrame(QJsonObject{{QStringLiteral("accepted"), false}}));
    socket->disconnectFromServer();
}

void ActivationChannel::readConnection(QLocalSocket *socket)
{
    if (socket->property("activationComplete").toBool()
        || socket->property("activationBuffered").toBool()) return;
    QByteArray buffer = socket->property("activationBuffer").toByteArray();
    buffer.append(socket->read(static_cast<qint64>(maximumActivationPayloadBytes)
                               + sizeof(quint32) + 1));
    if (socket->bytesAvailable() > 0
        || buffer.size() > static_cast<qsizetype>(maximumActivationPayloadBytes
                                                 + sizeof(quint32))) {
        rejectConnection(socket);
        return;
    }
    if (buffer.size() < static_cast<qsizetype>(sizeof(quint32))) {
        socket->setProperty("activationBuffer", buffer);
        return;
    }
    quint32 networkLength = 0;
    std::memcpy(&networkLength, buffer.constData(), sizeof(networkLength));
    const quint32 length = qFromBigEndian(networkLength);
    if (length == 0 || length > maximumActivationPayloadBytes) {
        rejectConnection(socket);
        return;
    }
    if (buffer.size() < static_cast<qsizetype>(sizeof(quint32) + length)) {
        socket->setProperty("activationBuffer", buffer);
        return;
    }
    if (buffer.size() != static_cast<qsizetype>(sizeof(quint32) + length)) {
        rejectConnection(socket);
        return;
    }
    const QString payload = QString::fromUtf8(buffer.mid(sizeof(quint32)));
    if (!validActivationPayload(payload, true)) {
        rejectConnection(socket);
        return;
    }
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(payload.toUtf8(), &parseError);
    const QJsonObject object = document.object();
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        rejectConnection(socket);
        return;
    }
    const QString normalized = QString::fromUtf8(
        QJsonDocument(object).toJson(QJsonDocument::Compact));
    if (object.contains(QStringLiteral("background"))) {
        acknowledgeConnection(socket);
        return;
    }
    deliverActivation(normalized, socket);
}
