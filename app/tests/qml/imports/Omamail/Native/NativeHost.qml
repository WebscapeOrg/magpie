pragma Singleton
import QtQuick

QtObject {
  property var manifest: ({})
  property var settings: ({})
  property string backendPath: ""
  property var backendContract: ({apiVersion:8, releasedApiVersion:7, contractHash:"", unreleasedMethods:[]})
}
