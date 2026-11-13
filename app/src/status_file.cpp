#include "status_file.h"
#include "runtime.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>

#include <cmath>

#ifndef Q_OS_WIN
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace {
void setError(QString *error, const QString &message)
{
    if (error) *error = message;
}

bool booleanField(const QVariantMap &snapshot, const QString &name, bool fallback)
{
    const QVariant value = snapshot.value(name);
    return value.metaType().id() == QMetaType::Bool ? value.toBool() : fallback;
}

bool safeStatusTarget(const QString &path, QString *error)
{
    const QFileInfo info(path);
    if (!info.exists() && !info.isSymLink()) return true;
    if (info.isSymLink() || !info.isFile()) {
        setError(error, QStringLiteral("Native status file is unsafe"));
        return false;
    }
#ifndef Q_OS_WIN
    const auto unsafe = QFileDevice::ReadGroup | QFileDevice::WriteGroup
        | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::WriteOther
        | QFileDevice::ExeOther;
    struct stat details {};
    const QByteArray native = QFile::encodeName(path);
    if (::lstat(native.constData(), &details) != 0 || details.st_uid != geteuid()
        || details.st_nlink != 1 || (info.permissions() & unsafe)) {
        setError(error, QStringLiteral("Native status file is not private"));
        return false;
    }
#endif
    return true;
}
}

BarStatus sanitizedBarStatus(const QVariantMap &snapshot)
{
    BarStatus status;
    status.ready = booleanField(snapshot, QStringLiteral("ready"), false);
    status.windowOpen = booleanField(snapshot, QStringLiteral("windowOpen"), false);
    status.showBarIcon = booleanField(snapshot, QStringLiteral("showBarIcon"), true);
    const QVariant unread = snapshot.value(QStringLiteral("unreadTotal"));
    const int type = unread.metaType().id();
    const bool numeric = type == QMetaType::Int || type == QMetaType::UInt
        || type == QMetaType::LongLong || type == QMetaType::ULongLong
        || type == QMetaType::Double || type == QMetaType::Float;
    const double value = numeric ? unread.toDouble() : 0.0;
    if (numeric && std::isfinite(value) && value > 0)
        status.unreadTotal = static_cast<qint64>(std::min(value, 9007199254740991.0));
    return status;
}

StatusFile::StatusFile(QString runtimeDirectory)
    : m_runtimeDirectory(std::move(runtimeDirectory))
{
}

QString StatusFile::path() const
{
    return QDir(m_runtimeDirectory).filePath(QStringLiteral("status.json"));
}

bool StatusFile::write(const BarStatus &status, QString *error)
{
    if (!ensureRuntimeDirectory(m_runtimeDirectory, error)
        || !safeStatusTarget(path(), error)) return false;
    m_status = status;
    const QJsonObject object{
        {QStringLiteral("ready"), status.ready},
        {QStringLiteral("windowOpen"), status.windowOpen},
        {QStringLiteral("showBarIcon"), status.showBarIcon},
        {QStringLiteral("unreadTotal"), static_cast<double>(status.unreadTotal)},
        {QStringLiteral("updated"), QDateTime::currentMSecsSinceEpoch()},
    };
    const QByteArray bytes = QJsonDocument(object).toJson(QJsonDocument::Compact);
    QSaveFile file(path());
    if (!file.open(QIODevice::WriteOnly)) {
        setError(error, QStringLiteral("Could not open native status file: %1")
                         .arg(file.errorString()));
        return false;
    }
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    if (file.write(bytes) != bytes.size() || !file.commit()
        || !safeStatusTarget(path(), error)) {
        setError(error, QStringLiteral("Could not atomically publish native status"));
        return false;
    }
    if (error) error->clear();
    return true;
}

bool StatusFile::shutdown(QString *error)
{
    BarStatus stopped = m_status;
    stopped.ready = false;
    stopped.windowOpen = false;
    if (write(stopped, error)) return true;

    // Invariant: If the final atomic write is impossible, a stale ready:true record is
    // worse than no record. Remove only a target that passes the same link and owner checks.
    const QString publishError = error ? *error : QString{};
    if (ensureRuntimeDirectory(m_runtimeDirectory, nullptr)
        && safeStatusTarget(path(), nullptr)) {
        const QFileInfo info(path());
        if ((!info.exists() && !info.isSymLink()) || QFile::remove(path())) {
            if (error) error->clear();
            return true;
        }
    }
    if (error && !publishError.isEmpty()) *error = publishError;
    return false;
}
