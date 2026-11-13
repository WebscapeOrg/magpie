#pragma once

#include <QString>

// The native shell envelope shares one private directory for activation and status.
QString defaultRuntimeDirectory(QString *error = nullptr);
bool ensureRuntimeDirectory(const QString &path, QString *error = nullptr);
