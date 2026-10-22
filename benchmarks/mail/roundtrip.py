#!/usr/bin/env python3
"""Compare frozen Qt JS with actual QML→Rust→QML processing, including uploads."""
import argparse,hashlib,json,os,platform,shutil,signal,subprocess,tempfile,time,tomllib
from pathlib import Path
from corpus import corpus
from run import mime_semantics,html_semantics,difference,digest,stats,fingerprints,verify_unchanged,validate_samples
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
QML=r'''
import QtQuick
import Quickshell
import "backend" as BackendModule
import "baseline/message/Message.js" as Message
import "baseline/message/Html.js" as Html
import "baseline/message/Direction.js" as Direction
Scope {
 id: root
 property var cases: PAYLOAD
 property int sampleCount: SAMPLES
 property var phases: ["mime","html","readprep"]
 property int caseIndex: 0
 property int phaseIndex: 0
 property bool began: false
 property string raw: ""
 property var oldRow: null
 property var result: null
 property var samples: []
 property int sampleIndex: -5
 property int operation: 0
 property int batch: 1
 property real start: 0
 property real cold: 0
 function fail(message) { console.log("ROUNDTRIP_ERROR "+message); Qt.quit() }
 function oldOperation() {
  var item=cases[caseIndex], phase=phases[phaseIndex]
  if(phase==="mime") return Message.parseRfc822(raw)
  var value=Html.sanitize(item.html,phase==="readprep"?{withPlainText:true,withReader:true}:{})
  if(value.plainText)value.plainText.bodyDirection=Direction.resolveBody(value.plainText.text,"Auto")
  return value
 }
 function beginCase() {
  if(caseIndex>=cases.length){
   backend.shutdown(function(error){if(error)root.fail(error.message);else{console.log("ROUNDTRIP_DONE");Qt.quit()}})
   return
  }
  if(phaseIndex===0)raw=Message.bytesToLatin1(Message.base64ToBytes(cases[caseIndex].raw))
  var started=Date.now(), value=oldOperation(), first=(Date.now()-started)*1000
  for(var w=0;w<5;w++)value=oldOperation()
  var count=1, elapsed=0
  while(true){
   started=Date.now()
   for(var k=0;k<count;k++)value=oldOperation()
   elapsed=Date.now()-started
   if(elapsed>=20||count>=2048)break
   count*=2
  }
  var times=[]
  for(var n=0;n<sampleCount;n++){
   started=Date.now()
   for(var j=0;j<count;j++)value=oldOperation()
   times.push((Date.now()-started)*1000/count)
  }
  oldRow={coldUs:first,batch:count,samplesUs:times,result:value}
  sampleIndex=-6;operation=0;samples=[]
  var bytes=phases[phaseIndex]==="mime"?raw.length:cases[caseIndex].html.length
  batch=bytes<=4096?32:(bytes<=65536?8:1)
  nextNative()
 }
 function nextNative() {
  var count=sampleIndex<0?1:batch
  if(operation===0)start=Date.now()
  var finished=function(value,error){
   var end=Date.now()
   if(error||!value||typeof value!=="object"){root.fail("native processing failed: "+JSON.stringify(error));return}
   root.result=value
   root.operation++
   if(root.operation<count){root.nextNative();return}
   var elapsed=(end-root.start)*1000/count
   if(root.sampleIndex===-6)root.cold=elapsed
   if(root.sampleIndex>=0)root.samples.push(elapsed)
   root.operation=0;root.sampleIndex++
   if(root.sampleIndex<root.sampleCount){root.nextNative();return}
   var row={name:root.cases[root.caseIndex].name,phase:root.phases[root.phaseIndex],
    qml:root.oldRow,native:{coldUs:root.cold,batch:root.batch,samplesUs:root.samples,result:root.result}}
   // Logging/validation is outside measured operations, split into bounded lines.
   var text=JSON.stringify(row), total=Math.ceil(text.length/32768)
   for(var i=0;i<total;i++)console.log("ROUNDTRIP_PART "+JSON.stringify({index:i,total:total,data:text.slice(i*32768,(i+1)*32768)}))
   console.log("ROUNDTRIP_PROGRESS "+row.name+"/"+row.phase)
   root.oldRow=null;root.result=null;root.samples=[]
   root.phaseIndex++
   if(root.phaseIndex>=root.phases.length){root.phaseIndex=0;root.caseIndex++}
   Qt.callLater(root.beginCase)
  }
  if(phases[phaseIndex]==="mime")backend.parseMessage(raw,finished)
  else backend.call("message.render",{html:cases[caseIndex].html,
    options:phases[phaseIndex]==="readprep"?{withPlainText:true,withReader:true}:{}},finished)
 }
 BackendModule.Backend {
  id: backend
  executable: BINARY
  expectedVersion: VERSION
  expectedApiVersion: API_REVISION
  onReadyChanged:if(ready&&!root.began){root.began=true;Qt.callLater(root.beginCase)}
  onFailureChanged:if(failure!=="")root.fail(failure)
 }
 Timer{interval:900000;running:true;onTriggered:root.fail("whole run deadline")}
}
'''
def render(report):
    lines=['# Mail processing including QML ↔ Rust transport','',f"Measured {report['date']} on {report['cpu']}; {report['samples']} samples, five warmups.",
     '','All times below are milliseconds per operation. Ratios above 1 mean the Rust path was faster.',
     '','| Case / stage | Previous Qt JS median / p95 | Rust + full RPC median / p95 | Qt / full RPC | Equal output |',
     '|---|---:|---:|---:|---|']
    for row in report['results']:
        qml_stats,native_stats=row['qml'],row['native']
        lines.append(f"| {row['name']} / {row['phase']} | {qml_stats['medianUs']/1000:.3f} / {qml_stats['p95Us']/1000:.3f} | {native_stats['medianUs']/1000:.3f} / {native_stats['p95Us']/1000:.3f} | {row['speedup']:.2f}× | {'yes' if row['semanticMatch'] else 'NO'} |")
    lines+=['','The Rust column is measured directly from the QML call to its completed callback, using the release application backend and unchanged production Backend.qml/Upload.js/Chunks.js/Wire.js. It includes outgoing parameter serialization, JavaScript base64/UTF-8 upload encoding, upload.begin/append round trips where used, Rust dispatch and processing, response serialization/chunking, pipe transfer, QML reassembly/JSON parsing and callback dispatch. It is not the old CPU time plus an estimated transfer constant.','',
      'Both paths start with the same input already held in QML. MIME uses Backend.parseMessage; HTML stages use message.render with no cache identity, so a render cache hit cannot replace processing. Each stage is independent: HTML is pre-extracted, and readprep includes sanitization, plain-text extraction and reader-document preparation. Network access, disk reads, application startup, initial corpus decoding, report serialization and UI drawing are excluded. This represents processing requested from QML, not the native-provider/preloaded-cache path that keeps input in Rust.','',
      'The same frozen Qt JavaScript baseline is rerun in this process. Cold calls and five warmups precede each engine’s timed samples; Qt JS batches calibrate to at least 20 ms, capped at 2048 operations. Native small requests use fixed batches (32 or 8), large requests use one operation per sample. QML Date.now has 1 ms resolution; small native results are batch averages and include callback bookkeeping between operations. Final outputs are compared by decoded MIME bytes/tree semantics or complete normalized HTML outputs outside timing. The shared desktop and GC can affect results.','',
      f"Load before: {report['loadBefore']}; after: {report['loadAfter']}. Versions: {report['versions']}.",
      '', 'Reproduce: `python3 benchmarks/mail/roundtrip.py`. Raw samples, corpus/source/binary hashes and versions are in roundtrip-results.json. The separate results.md remains a CPU-only diagnostic, not the headline performance comparison.']
    return '\n'.join(lines)+'\n'
def build_backend():
    build=subprocess.run(['cargo','build','--locked','--release','--bin','omamail','--message-format=json'],
                         cwd=ROOT,check=True,stdout=subprocess.PIPE,text=True)
    artifacts=[json.loads(line) for line in build.stdout.splitlines() if line.strip()]
    executables=[item['executable'] for item in artifacts if item.get('reason')=='compiler-artifact'
                 and item.get('target',{}).get('name')=='omamail'
                 and item.get('target',{}).get('kind')==['bin'] and item.get('executable')]
    if len(executables)!=1:raise RuntimeError('Expected one built omamail executable')
    binary=Path(executables[0])
    return binary


def roundtrip_results(output,cases):
    rows=[];parts=[];total=None
    for line in output.splitlines():
        if 'ROUNDTRIP_PART ' not in line:continue
        part=json.loads(line.split('ROUNDTRIP_PART ',1)[1])
        if not parts:total=part['total']
        if part['index']!=len(parts) or part['total']!=total:raise RuntimeError('Broken benchmark report transfer')
        parts.append(part['data'])
        if len(parts)==total:rows.append(json.loads(''.join(parts)));parts=[];total=None
    expected=[(case['name'],p) for case in cases for p in ['mime','html','readprep']]
    if parts or [(row['name'],row['phase']) for row in rows]!=expected:raise RuntimeError('Incomplete benchmark results')
    return rows


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--samples',type=int,default=31)
    parser.add_argument('--cases',nargs='+',choices=[case['name'] for case in corpus()])
    args=parser.parse_args()
    if not 3<=args.samples<=1000:parser.error('samples must be 3..1000')
    manifest=json.loads((HERE/'baseline/manifest.json').read_text())
    for relative,expected_hash in manifest['sha256'].items():
        if hashlib.sha256((HERE/'baseline/ui'/relative).read_bytes()).hexdigest()!=expected_hash:raise RuntimeError('Frozen baseline changed')
    cases=corpus()
    if args.cases:cases=[case for case in cases if case['name'] in args.cases]
    binary=build_backend()
    sources=[path for base in ['src','ui/backend','ui/message'] for path in sorted((ROOT/base).rglob('*')) if path.is_file()]
    harness=[Path(__file__),HERE/'corpus.py',HERE/'run.py']
    provenance=fingerprints([binary,*sources,*harness])
    version=tomllib.loads((ROOT/'Cargo.toml').read_text())['package']['version']
    env={k:v for k,v in os.environ.items() if not k.startswith(('QML','QS_'))}
    env.pop('WAYLAND_DISPLAY',None)
    env.update(QT_QPA_PLATFORM='offscreen',QT_QUICK_BACKEND='software',QT_QPA_PLATFORMTHEME='')
    versions={'rust':subprocess.check_output(['rustc','--version'],text=True).strip(),
      'qt':subprocess.check_output(['/usr/lib/qt6/bin/qml','--version'],env=env,text=True,stderr=subprocess.DEVNULL).strip(),
      'quickshell':subprocess.check_output([shutil.which('qs'),'--version'],env=env,text=True,stderr=subprocess.DEVNULL).strip()}
    with tempfile.TemporaryDirectory(prefix='omamail-roundtrip-') as folder:
        temp=Path(folder)
        for key in ['HOME','XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_DATA_HOME','XDG_STATE_HOME','XDG_RUNTIME_DIR']:
            path=temp/key.lower();path.mkdir(mode=0o700);env[key]=str(path)
        for module in ['backend','message']:shutil.copytree(ROOT/'ui'/module,temp/module)
        shutil.copytree(HERE/'baseline/ui',temp/'baseline')
        qml=QML.replace('API_REVISION',str(json.loads((ROOT/'backend-api.json').read_text())['apiVersion'])).replace('PAYLOAD',json.dumps(cases)).replace('SAMPLES',str(args.samples)).replace('BINARY',json.dumps(str(binary))).replace('VERSION',json.dumps(version))
        (temp/'shell.qml').write_text(qml)
        load_before=os.getloadavg();start=time.perf_counter()
        process=subprocess.Popen([shutil.which('qs'),'--no-color','--path',str(temp/'shell.qml')],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        try:output,_=process.communicate(timeout=920)
        except subprocess.TimeoutExpired:
            # Invariant: the timed-out leader has not been reaped, so its process-group identity is reserved.
            try:os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            process.communicate()
            raise
        if process.returncode!=0 or 'ROUNDTRIP_ERROR' in output or 'ROUNDTRIP_DONE' not in output:raise RuntimeError(output[-6000:])
        verify_unchanged(provenance)
        rows=roundtrip_results(output,cases)
        results=[]
        for row in rows:
            validate_samples(row['qml'],args.samples)
            validate_samples(row['native'],args.samples)
            canonical=mime_semantics if row['phase']=='mime' else html_semantics
            qml_result,native_result=canonical(row['qml']['result']),canonical(row['native']['result'])
            qml_stats,native_stats=stats(row['qml']),stats(row['native'])
            results.append(dict(name=row['name'],phase=row['phase'],qml={**qml_stats,'batch':row['qml']['batch']},native={**native_stats,'batch':row['native']['batch']},semanticMatch=qml_result==native_result,semanticDifference=difference(qml_result,native_result),qmlDigest=digest(qml_result),nativeDigest=digest(native_result),speedup=qml_stats['medianUs']/native_stats['medianUs']))
        report={'date':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'cpu':next(line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),'platform':platform.platform(),'versions':versions,'samples':args.samples,'loadBefore':load_before,'loadAfter':os.getloadavg(),'wallSeconds':time.perf_counter()-start,'baseline':manifest,'corpus':[dict({k:v for k,v in case.items() if k not in ['raw','html']}, htmlSha256=hashlib.sha256(case['html'].encode('utf-8')).hexdigest()) for case in cases],'binarySha256':provenance[str(binary)],'sourceSha256':{str(path.relative_to(ROOT)):provenance[str(path)] for path in sources},'harnessSha256':{path.name:provenance[str(path)] for path in harness},'results':results}
        (HERE/'roundtrip-results.json').write_text(json.dumps(report,indent=2)+'\n')
        (HERE/'roundtrip-results.md').write_text(render(report))
        print(render(report))
        if not all(row['semanticMatch'] for row in results):raise SystemExit('Output mismatch: ratios are not comparable-work evidence')
if __name__=='__main__':main()
