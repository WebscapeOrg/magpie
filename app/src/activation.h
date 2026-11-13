#pragma once

#include <QLocalServer>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>

class QLocalSocket;

inline constexpr qsizetype maximumMailtoUrlBytes = 16 * 1024;
inline constexpr quint32 maximumActivationPayloadBytes = 32 * 1024;

struct LaunchOptions {
    enum class Action { Open, Background, Compose, Mailto, CheckResources, SmokeTest };

    bool ok = false;
    Action action = Action::Open;
    QString activationPayload;
    QString smokeReadyFile;
    QString error;
};

LaunchOptions parseLaunchArguments(const QList<QByteArray> &arguments);
bool validActivationPayload(const QString &payload, bool allowBackground = false);

class ActivationChannel final : public QObject {
    Q_OBJECT

public:
    enum class Role { Primary, Secondary };
    enum class HandoffResult { Acknowledged, Unavailable, Failed };

    explicit ActivationChannel(QObject *parent = nullptr);
    explicit ActivationChannel(QString runtimeDirectory, QObject *parent = nullptr);
    ~ActivationChannel() override;

    QString runtimeDirectory() const { return m_runtimeDirectory; }
    QString socketPath() const;
    bool isListening() const { return m_server.isListening(); }
    bool acquire(const QString &payload, Role *role, QString *error,
                 int timeoutMilliseconds = 2000);
    HandoffResult handOff(const QString &payload, QString *error,
                          int timeoutMilliseconds = 2000) const;
    void suspendDelivery();
    bool enableDelivery();
    void rejectPendingActivations();
    QStringList takePendingActivations();
    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    void activationRequested(const QString &payload);

private:
    struct PendingActivation {
        QString payload;
        QPointer<QLocalSocket> socket;
    };

    void acceptConnections();
    void readConnection(QLocalSocket *socket);
    void acknowledgeConnection(QLocalSocket *socket);
    void rejectConnection(QLocalSocket *socket);
    void deliverActivation(const QString &payload, QLocalSocket *socket = nullptr);
    bool removeStaleSocket(QString *error) const;

    QString m_runtimeDirectory;
    QLocalServer m_server;
    QList<PendingActivation> m_pendingActivations;
    bool m_deliverySuspended = false;
    bool m_deliveryFailed = false;
};
