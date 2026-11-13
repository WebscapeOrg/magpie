#pragma once

#include "file_store.h"
#include "notifications.h"

#include <QObject>
#include <QUrl>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#include <memory>

class StatusFile;

class ApplicationHost : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(NativeHost)
    QML_SINGLETON

    Q_PROPERTY(QVariantMap manifest READ manifest CONSTANT)
    Q_PROPERTY(QVariantMap capabilities READ capabilities CONSTANT)
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    Q_PROPERTY(QString backendPath READ backendPath CONSTANT)
    Q_PROPERTY(QString resourceRoot READ resourceRoot CONSTANT)
    Q_PROPERTY(QVariantMap backendContract READ backendContract CONSTANT)
    Q_PROPERTY(QString notificationError READ notificationError
               NOTIFY notificationErrorChanged)
    Q_PROPERTY(QVariantMap pendingNotificationActivation
               READ pendingNotificationActivation
               NOTIFY pendingNotificationActivationChanged)
    Q_PROPERTY(QString initialActivation READ initialActivation CONSTANT)
    Q_PROPERTY(bool startInBackground READ startInBackground CONSTANT)

public:
    explicit ApplicationHost(QObject *parent = nullptr);
    ~ApplicationHost() override;
    ApplicationHost(QString manifestPath, QString backendPath,
                    QString settingsPath, QObject *parent = nullptr);
    ApplicationHost(QString manifestPath, QString backendPath,
                    QString settingsPath,
                    std::unique_ptr<NotificationPlatform> notificationPlatform,
                    QObject *parent = nullptr);

    QVariantMap manifest() const { return m_manifest; }
    QVariantMap capabilities() const { return m_capabilities; }
    QVariantMap settings() const { return m_settings; }
    QString backendPath() const { return m_backendPath; }
    QString resourceRoot() const;
    QVariantMap backendContract() const;
    QString notificationError() const;
    QVariantMap pendingNotificationActivation() const
    {
        return m_pendingNotificationActivation;
    }
    QString initialActivation() const { return m_initialActivation; }
    bool startInBackground() const { return m_startInBackground; }

    bool configureStatusWriter(const QString &runtimeDirectory, QString *error = nullptr);
    void activate(const QString &payload);
    Q_INVOKABLE bool updateBarStatus(const QVariantMap &snapshot);
    Q_INVOKABLE bool openExternal(const QString &urlOrPath);
    Q_INVOKABLE bool openMessageLink(const QString &url, const QString &accountEmail);
    Q_INVOKABLE bool setClipboard(const QString &text);
    Q_INVOKABLE bool showNotification(const QString &id, const QString &title,
                                      const QString &body, const QString &accountId,
                                      const QString &messageId);
    Q_INVOKABLE QVariantMap takePendingNotificationActivation();
    Q_INVOKABLE void hide();
    Q_INVOKABLE void quit();
    // Invariant: The platform close chord arrived at the native layer, ahead of Qt's key
    // delivery. The window decides what leaving means; the host only relays.
    void requestClose();
    // Invariant: The application became active while every window was hidden — a Dock
    // or taskbar click on a process whose window was shut.
    void handleApplicationStateChanged(Qt::ApplicationState state);
    Q_INVOKABLE bool updateSettings(const QVariantMap &settings);
    Q_INVOKABLE QString environment(const QString &name) const;
    Q_INVOKABLE QString configPath(const QString &name) const;
    Q_INVOKABLE QString cachePath(const QString &name) const;
    Q_INVOKABLE QString localFilePath(const QUrl &url) const;

signals:
    void settingsChanged();
    void hideRequested();
    void reopenRequested();
    void closeRequested();
    void notificationErrorChanged();
    void pendingNotificationActivationChanged();
    void notificationActivated(const QString &accountId, const QString &messageId);
    void activationRequested(const QString &payload);

private:
    void loadManifest(const QString &path);
    void shutdownStatus();
    void activateFromNotification(const QString &accountId, const QString &messageId);

    QVariantMap m_manifest;
    QVariantMap m_capabilities;
    QVariantMap m_settings;
    QString m_backendPath;
    SettingsStore m_store;
    std::unique_ptr<Notifications> m_notifications;
    QVariantMap m_pendingNotificationActivation;
    QString m_initialActivation = QStringLiteral("{}");
    bool m_startInBackground = false;
    std::unique_ptr<StatusFile> m_statusFile;
    bool m_statusShutdown = false;
};
