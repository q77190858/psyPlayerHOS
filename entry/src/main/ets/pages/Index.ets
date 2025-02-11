import { webview } from '@kit.ArkWeb';
import { BusinessError,zlib } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, ReadTextOptions, fileUri, picker, Environment } from '@kit.CoreFileKit';
import hilog from '@ohos.hilog';
import { JSON } from '@kit.ArkTS';
import { window } from '@kit.ArkUI'

class ElectronAPI {
  constructor() {
  }

  async openDir(): Promise<string> {
    let zipPath: string = ""
    let folderPath: string = ""
    try {
      // const documentPath = Environment.getUserDocumentDir()
      let documentSelectOptions = new picker.DocumentSelectOptions()
      // documentSelectOptions.defaultFilePathUri = fileUri.getUriFromPath(documentPath)
      // documentSelectOptions.selectMode = picker.DocumentSelectMode.FOLDER; //only select folder
      // documentSelectOptions.authMode = true;
      documentSelectOptions.fileSuffixFilters=[".zip"]
      documentSelectOptions.maxSelectNumber=1
      let context = getContext() as common.Context;
      let documentPicker = new picker.DocumentViewPicker(context);
      let documentSelectResult = await documentPicker.select(documentSelectOptions)
      if (documentSelectResult.length > 0) {
        let uri = new fileUri.FileUri(documentSelectResult[0])
        zipPath = uri.path
      }
    } catch (error) {
      let err: BusinessError = error as BusinessError;
      console.error('DocumentViewPicker failed with err: ' + JSON.stringify(err));
    }
    // if (!canIUse('SystemCapability.FileManagement.File.Environment.FolderObtain')) {
    //   console.error('this api is not supported on this device');
    //   return "";
    // }
    if (zipPath != "") {
      console.log(zipPath)
      let context = getContext() as common.Context;
      let pathDir = context.filesDir;
      let outFileDir = pathDir+'/course';
      try {
        let res = fs.accessSync(outFileDir);
        if (res) {
          fs.rmdirSync(outFileDir)
        }
        fs.mkdirSync(outFileDir)

      } catch(error) {
        let err: BusinessError = error as BusinessError;
        console.error("access mk rm dir failed with error message: " + err.message + ", error code: " + err.code);
      }
      try {
        await zlib.decompressFile(zipPath, outFileDir)
      } catch (errData) {
        let code = (errData as BusinessError).code;
        let message = (errData as BusinessError).message;
        console.error(`decompressFile failed. code is ${code}, message is ${message}`);
      }

      folderPath = outFileDir
      let str = fs.readTextSync(folderPath + "/commandsV3.json")
      let commandsV3 = JSON.parse(str)
      str = fs.readTextSync(folderPath + "/playback.json")
      let playback = JSON.parse(str)
      let msgList = new Array<object>()
      for (let i = 0; i < Object(commandsV3)['msg'].length; i++) {
        let msgFileName: string = Object(commandsV3)['msg'][i]['loc'].split("/").pop()
        str = fs.readTextSync(folderPath + "/" + msgFileName)
        let msg: Array<object> = Object(JSON.parse(str))["list"]
        msgList = msgList.concat(msg)
      }
      let pageList = new Array<object>()
      for (let i = 0; i < Object(commandsV3)['pages'].length; i++) {
        let p: object = Object(commandsV3)['pages'][i]
        if (Object(p)["drawfile"]) {
          let str = fs.readTextSync(folderPath + "/" + p["drawfile"])
          let draw = JSON.parse(str)
          p["draw"] = draw
        }
        pageList.push(p)
      }
      hilog.debug(0x0000, "limo", JSON.stringify([folderPath, commandsV3, playback, msgList, pageList]))
      return JSON.stringify([folderPath, commandsV3, playback, msgList, pageList])
    }
    return ""
  }
}

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State electronAPI: ElectronAPI = new ElectronAPI();
  // 构造本地文件和构造返回的格式mimeType
  mimeTypeMap = new Map([
    ["index.html", 'text/html'],
    ["js/script.js", "text/javascript"]
  ])

  aboutToAppear(): void {
    window.getLastWindow(getContext()).then((win)=>{
      // 2. 指定页面开启
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarEnable([]);
    })
    try {
      webview.WebviewController.setWebDebuggingAccess(true);
    } catch (error) {
      console.error(`ErrorCode: ${(error as BusinessError).code},  Message: ${(error as BusinessError).message}`);
    }
  }

  build() {
    Column() {
      Web({ src: $rawfile('index.html'), controller: this.controller })// 将对象注入到web端
        .javaScriptAccess(true)
        .fileAccess(true)
        .domStorageAccess(true)
        .geolocationAccess(true)
        .width("100%")
        .height("100%")
        .javaScriptProxy({
          object: this.electronAPI,
          name: "electronAPI",
          methodList: ["openDir"],
          controller: this.controller,
          // 可选参数
          asyncMethodList: [],
        })
        .onInterceptRequest((event) => {
          if (!event) {
            return;
          }
          // 此处匹配自己想要加载的本地离线资源，进行资源拦截替换，绕过跨域
          if (event.request.getRequestUrl().startsWith("http://")) {
            let realPath: string = decodeURI(event.request.getRequestUrl().substring(7))
            console.log("limo realPath: ", realPath)
            let stat = fs.statSync(realPath)
            if (realPath.endsWith(".jpg")) {
              let file = fs.openSync(realPath, fs.OpenMode.READ_ONLY)
              let buf = new ArrayBuffer(stat.size);
              fs.readSync(file.fd, buf)
              fs.closeSync(file.fd)
              let response = new WebResourceResponse();
              response.setResponseData(buf);
              response.setResponseEncoding('utf-8');
              response.setResponseMimeType('image/jpg');
              response.setResponseCode(200);
              response.setReasonMessage('OK');
              response.setResponseIsReady(true);
              return response;
            } else if (realPath.endsWith(".mp4")) {
              let headers = event.request.getRequestHeader()
              let ranges = Array<number>()
              for (let header of headers) {
                if (header.headerKey == "Range") {
                  let r = header.headerValue.split("=")[1]
                  ranges.push(Number(r.split("-")[0]))
                }
              }
              console.log("limo video request: ", JSON.stringify(ranges))
              let file = fs.openSync(realPath, fs.OpenMode.READ_ONLY)
              let buf = new ArrayBuffer(10 * 1024 * 1024);
              let redLen = fs.readSync(file.fd, buf, { offset: ranges[0] })
              fs.closeSync(file.fd)
              let response = new WebResourceResponse();
              response.setResponseData(buf);
              // response.setResponseEncoding('utf-8');
              response.setResponseMimeType('video/mp4');
              response.setResponseCode(206);
              response.setReasonMessage('Partial Content');
              response.setResponseHeader([
                {headerKey:"Accept-Ranges",headerValue:"bytes"},
                {headerKey:"Content-Range",headerValue:`bytes ${ranges[0]}-${ranges[0]+redLen-1}/${stat.size-1}}`},
                {headerKey:"Content-Length",headerValue:String(redLen)},
                {headerKey:"Content-Type",headerValue:"video/mp4"}])
              response.setResponseIsReady(true);
              console.log("limo video response: ",JSON.stringify(response.getResponseHeader()))
              return response;
            }
          }
          return null;
        })
    }
  }
}