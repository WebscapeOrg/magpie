#include "runtime.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

#ifndef Q_OS_WIN
#include <unistd.h>
#endif

namespace {
void setError(QString *error, const QString &message)
{
    if (error) *error = message;
}

#ifndef Q_OS_WIN
bool privatelyOwned(const QFileInfo &info)
{
    return info.ownerId() == static_cast<uint>(geteuid());
}
#endif

bool safeParentDirectory(const QString &path, QString *error)
{
    const QFileInfo info(path);
    if (!info.exists() || info.isSymLink() || !info.isDir()) {
        setError(error, QStringLiteral("Native runtime parent is not a safe directory"));
        return false;
    }
#ifndef Q_OS_WIN
    const auto unsafe = QFileDevice::WriteGroup | QFileDevice::WriteOther;
    if (!privatelyOwned(info) || (info.permissions() & unsafe)) {
        setError(error, QStringLiteral("Native runtime parent is not private"));
        return false;
    }
#endif
    return true;
}
}

QString defaultRuntimeDirectory(QString *error)
{
    QString root = QString::fromLocal8Bit(qgetenv("XDG_RUNTIME_DIR"));
    if (root.isEmpty())
        root = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (root.isEmpty() || !QDir::isAbsolutePath(root)
        || QDir::fromNativeSeparators(root).split('/').contains(QStringLiteral(".."))) {
        setError(error, QStringLiteral("XDG_RUNTIME_DIR does not provide a safe absolute path"));
        return {};
    }
    if (error) error->clear();
    return QDir(QDir::cleanPath(root)).filePath(QStringLiteral("magpie-mail"));
}

bool ensureRuntimeDirectory(const QString &path, QString *error)
{
    if (path.isEmpty() || !QDir::isAbsolutePath(path)
        || QDir::fromNativeSeparators(path).split('/').contains(QStringLiteral(".."))
        || QDir::cleanPath(path) != QDir::fromNativeSeparators(path)) {
        setError(error, QStringLiteral("Native runtime path is invalid"));
        return false;
    }
    const QFileInfo before(path);
    if (before.isSymLink() || (before.exists() && !before.isDir())) {
        setError(error, QStringLiteral("Native runtime directory is unsafe"));
        return false;
    }
    if (!safeParentDirectory(QFileInfo(path).absolutePath(), error)) return false;
    if (!before.exists() && !QDir().mkdir(path)) {
        setError(error, QStringLiteral("Could not create native runtime directory"));
        return false;
    }
    QFile directory(path);
    if (!directory.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner
                                  | QFileDevice::ExeOwner)) {
        setError(error, QStringLiteral("Could not protect native runtime directory"));
        return false;
    }
    const QFileInfo info(path);
    const auto unsafe = QFileDevice::ReadGroup | QFileDevice::WriteGroup
        | QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::WriteOther
        | QFileDevice::ExeOther;
    if (info.isSymLink() || !info.isDir() || (info.permissions() & unsafe)) {
        setError(error, QStringLiteral("Native runtime directory is not private"));
        return false;
    }
#ifndef Q_OS_WIN
    if (!privatelyOwned(info)) {
        setError(error, QStringLiteral("Native runtime directory has the wrong owner"));
        return false;
    }
#endif
    if (error) error->clear();
    return true;
}
