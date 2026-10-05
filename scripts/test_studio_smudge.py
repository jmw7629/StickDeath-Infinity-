#!/usr/bin/env python3
"""Compile and exercise production Smudge sources on macOS; not native UI proof."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, time
ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['StickDeathInfinity/Models/Models.swift', 'StickDeathInfinity/Models/StudioBrush.swift', 'StickDeathInfinity/Services/StudioBrushRenderer.swift', 'StickDeathInfinity/Models/StudioDocument.swift', 'StickDeathInfinity/Models/StudioCommands.swift', 'StickDeathInfinity/App/AppConfig.swift', 'StickDeathInfinity/App/SpatterBackendClient.swift', 'StickDeathInfinity/Storage/DeviceStorageManager.swift', 'StickDeathInfinity/ViewModels/StudioViewModel.swift', 'StickDeathInfinity/Services/StudioImageImportService.swift', 'StickDeathInfinity/Services/StudioRasterImage.swift', 'StickDeathInfinity/Models/StudioSmudge.swift', 'StickDeathInfinity/Models/StudioBlur.swift', 'StickDeathInfinity/Services/StudioSmudgeCapture.swift', 'StickDeathInfinity/Services/StudioBlurCapture.swift', 'StickDeathInfinity/Services/StudioExportService.swift', 'StickDeathInfinity/Views/Studio/StudioFrameRenderer.swift', 'StickDeathInfinity/Extensions/Color+SD.swift', 'StickDeathInfinity/Models/StudioSmudgeDescriptor.swift', 'StickDeathInfinity/Models/StudioBlurDescriptor.swift', 'StickDeathInfinity/Services/StudioSmudgeReplay.swift', 'StickDeathInfinity/Services/StudioMovieExportService.swift', 'StickDeathInfinity/Services/StudioFillService.swift', 'StickDeathInfinity/Services/StudioColorSamplingService.swift', 'StickDeathInfinity/Services/StudioSmudgeSession.swift', 'StickDeathInfinity/Services/StudioBlurSession.swift', 'StickDeathInfinity/Services/StudioMuxCapture.swift', 'StickDeathInfinity/Services/StudioFillRegion.swift']

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output-directory',type=Path,required=True)
    args=parser.parse_args();out=args.output_directory.resolve();out.mkdir(parents=True,exist_ok=False)
    compiler=subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip()
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    env=os.environ.copy();env['TMPDIR']=str(out)
    for fixture in ['main','capture','replay','surfaces','cache','session']:
        sources=['StickDeathInfinity/Models/StudioSmudge.swift'] if fixture=='main' else SOURCES
        sources=sources+['Tests/StudioSmudge/'+fixture+'.swift']
        inputs=[{'path':p,'sha256':hashlib.sha256((ROOT/p).read_bytes()).hexdigest()} for p in sources]
        executable=out/fixture
        cmd=[compiler,'-whole-module-optimization','-Onone','-sdk',sdk,'-module-cache-path',str(out/'module-cache'),'-swift-version','5']
        if fixture!='main':cmd+=['-parse-as-library']
        cmd+=sources+['-o',str(executable)]
        record={'inputs':inputs,'compileCommand':cmd,'nativeUIRun':False}
        failed=False
        for phase,argv,limit in [('compile',cmd,300),('run',[str(executable),str(out)] if fixture=='main' else [str(executable)],120)]:
            log=out/(fixture+'-'+phase+'.log');start=time.monotonic()
            with log.open('xb') as stream:
                try:code=subprocess.run(argv,cwd=ROOT,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=limit).returncode
                except subprocess.TimeoutExpired:code=124
            record[phase+'Exit']=code;record[phase+'Seconds']=time.monotonic()-start
            if phase=='run' or code:print(log.read_text(errors='replace')[-8000:],flush=True)
            if code:failed=True;break
        for item in inputs:
            if hashlib.sha256((ROOT/item['path']).read_bytes()).hexdigest()!=item['sha256']:raise RuntimeError('Source changed during verification')
        (out/(fixture+'-result.json')).write_text(json.dumps(record,indent=2)+'\n')
        if failed:raise SystemExit(code if code>0 else 1)
        print('SMUDGE_'+fixture.upper()+'=PASS',flush=True)

if __name__=='__main__':main()
