#include "app_icon.h"

#include <QFile>
#include <QImage>
#include <QPixmap>
#include <QtEndian>

QIcon iconFromIcns(const QByteArray &icns)
{
    QIcon icon;
    if (icns.size() < 8 || !icns.startsWith("icns")) return icon;
    const qsizetype total = qMin<qsizetype>(icns.size(), qFromBigEndian<quint32>(icns.constData() + 4));
    for (qsizetype offset = 8; total - offset >= 8;) {
        const quint32 size = qFromBigEndian<quint32>(icns.constData() + offset + 4);
        if (size < 8 || size > quint64(total - offset)) break;
        const QByteArray payload = icns.mid(offset + 8, size - 8);
        if (payload.startsWith("\x89PNG")) {
            const QImage image = QImage::fromData(payload, "PNG");
            if (!image.isNull()) icon.addPixmap(QPixmap::fromImage(image));
        }
        offset += size;
    }
    return icon;
}

QIcon iconFromIcnsFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return {};
    return iconFromIcns(file.readAll());
}
