#pragma once

#include <QString>
#include <QVariantMap>

struct BarStatus {
    bool ready = false;
    bool windowOpen = false;
    bool showBarIcon = true;
    qint64 unreadTotal = 0;
};

BarStatus sanitizedBarStatus(const QVariantMap &snapshot);

class StatusFile {
public:
    explicit StatusFile(QString runtimeDirectory);

    QString path() const;
    bool write(const BarStatus &status, QString *error = nullptr);
    bool shutdown(QString *error = nullptr);

private:
    QString m_runtimeDirectory;
    BarStatus m_status;
};
