#!/usr/bin/env python3
"""Reproducible human-speech and controlled-stress replays for Ora.

Audio stays in ignored inputs/. Manifests retain origin, reference, transforms,
and checksums. Public dataset audio, derived stress audio, and TTS are labelled
separately. This script never reads application history or credentials.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import subprocess
import wave

import numpy as np
import requests
from scipy.signal import lfilter

RATE = 16000
SOURCES = {
    'libri': ('openslr/librispeech_asr', 'clean', 'test', 0, 30, 'CC-BY-4.0'),
    'libri-200': ('openslr/librispeech_asr', 'clean', 'test', 200, 100, 'CC-BY-4.0'),
    'ami': ('edinburghcstr/ami', 'ihm', 'test', 0, 30, 'CC-BY-4.0'),
    'ami-100': ('edinburghcstr/ami', 'ihm', 'test', 100, 100, 'CC-BY-4.0'),
    'ascend': ('CAiRE/ASCEND', 'main', 'test', 0, 30, 'CC-BY-SA-4.0'),
    'ascend-100': ('CAiRE/ASCEND', 'main', 'test', 100, 100, 'CC-BY-SA-4.0'),
    'aishell': ('TwinkStart/AISHELL-1', 'default', 'test', 0, 30, 'Apache-2.0 (AISHELL original)'),
    'aishell-500': ('TwinkStart/AISHELL-1', 'default', 'test', 500, 100, 'Apache-2.0 (AISHELL original)'),
    'minds-en-AU': ('PolyAI/minds14', 'en-AU', 'train', 0, 20, 'CC-BY-4.0'),
    'minds-en-GB': ('PolyAI/minds14', 'en-GB', 'train', 0, 20, 'CC-BY-4.0'),
}


def read_audio(path):
    with wave.open(str(path)) as file:
        assert file.getframerate() == RATE and file.getnchannels() == 1 and file.getsampwidth() == 2
        return np.frombuffer(file.readframes(file.getnframes()), dtype='<i2').astype(np.float64) / 32768


def write_audio(path, data):
    peak = np.max(np.abs(data)) if len(data) else 0
    if peak > 0.98:
        data = data * (0.98 / peak)
    with wave.open(str(path), 'wb') as file:
        file.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        file.writeframes((np.clip(data, -1, 1) * 32767).astype('<i2').tobytes())


def convert(source, target, filters=None):
    command = ['ffmpeg', '-nostdin', '-y', '-loglevel', 'error', '-i', str(source), '-ar', str(RATE), '-ac', '1']
    if filters:
        command += ['-af', filters]
    subprocess.run(command + ['-c:a', 'pcm_s16le', str(target)], check=True, capture_output=True)


def trim(data):
    indices = np.flatnonzero(np.abs(data) > max(0.002, np.max(np.abs(data)) * 0.01))
    return data[max(0, indices[0] - 800):min(len(data), indices[-1] + 1280)] if len(indices) else data


def prepare(root):
    inputs = root / 'inputs'
    inputs.mkdir(parents=True, exist_ok=True)
    (root / '.gitignore').write_text('inputs/\n')
    metadata = {}
    for tag, (dataset, config, split, offset, length, license_name) in SOURCES.items():
        cache = inputs / f'{tag}-rows.json'
        if not cache.exists():
            response = requests.get('https://datasets-server.huggingface.co/rows',
                params=dict(dataset=dataset, config=config, split=split, offset=offset, length=length), timeout=45)
            response.raise_for_status()
            cache.write_text(json.dumps(response.json(), ensure_ascii=False))
        for item in json.loads(cache.read_text())['rows']:
            metadata[tag, item['row_idx']] = (item['row'], dataset, config, split, license_name)

    needed = [('libri', i) for i in range(14)] + [('libri-200', i) for i in range(200, 221)]
    needed += [('ami-100', i) for i in (152, 177, 194)]
    needed += [('ascend', 9)] + [('ascend-100', i) for i in (138, 188)]
    needed += [('aishell', i) for i in (1, 2)] + [('aishell-500', i) for i in (503, 504)]
    needed += [('minds-en-AU', i) for i in (0, 1)] + [('minds-en-GB', i) for i in (0, 3)]

    def fetch(key):
        tag, index = key
        row, dataset, config, split, license_name = metadata[key]
        destination = inputs / f'{tag}-{index}.wav'
        if not destination.exists():
            raw = inputs / f'{tag}-{index}.download'
            response = requests.get(row['audio'][0]['src'], timeout=60)
            response.raise_for_status()
            raw.write_bytes(response.content)
            convert(raw, destination)
            raw.unlink()
        text = row.get('text', row.get('transcription', ''))
        if tag.startswith('aishell'):
            text = ''.join(text.split())
        origin = dict(dataset=dataset, config=config, split=split, row=index, license=license_name,
            source_id=row.get('id', row.get('audio_id', row.get('name', row.get('path')))),
            speaker=str(row.get('speaker_id', row.get('original_speaker_id', row.get('name', 'not supplied')))),
            url=f'https://huggingface.co/datasets/{dataset}', sha256=hashlib.sha256(destination.read_bytes()).hexdigest())
        return key, (read_audio(destination), text, origin)

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        clips = dict(pool.map(fetch, needed))
    fixtures = []
    def add(identifier, data, reference, language, target, category, origins, transforms=None, **extra):
        path = inputs / f'{identifier}.wav'
        write_audio(path, data)
        fixtures.append(dict(id=identifier, language=language, targetLanguage=target, reference=reference,
            referenceTranslation='', audioPath=str(path.resolve()), category=category,
            origins=origins, transforms=transforms or [], audioSeconds=len(data)/RATE,
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(), **extra))
    def human(identifier, keys, language, target, category='unaltered-human-recording', gap=0.3):
        samples=[]; references=[]; origins=[]
        for key in keys:
            audio, text, origin=clips[key]
            if samples: samples.append(np.zeros(int(gap*RATE)))
            samples.append(audio); references.append(text); origins.append(origin)
        add(identifier,np.concatenate(samples),' '.join(references),language,target,category,origins,
            transforms=[] if len(keys)==1 else [f'concatenate {len(keys)} recorded clips with {gap}s gaps'],
            **({'drainBudgetSeconds':120} if identifier=='stress_long_3min' else {}))
        return fixtures[-1]

    human('human_en_reader_a',[('libri',1)],'en','Chinese')
    human('human_en_reader_b',[('libri-200',202)],'en','Chinese')
    human('human_zh_voice_a',[('aishell',1),('aishell',2)],'zh','English','assembled-human-recordings')
    human('human_zh_voice_b',[('aishell-500',504)],'zh','English')
    human('human_australian_english',[('minds-en-AU',0)],'en','Chinese')
    human('human_british_english',[('minds-en-GB',3)],'en','Chinese')
    human('human_meeting_menus',[('ami-100',152)],'en','Chinese')
    human('human_meeting_weekend',[('ami-100',194)],'en','Chinese')
    human('human_codeswitch_major',[('ascend',9)],'mixed','English')
    human('human_codeswitch_jobs',[('ascend-100',138),('ascend-100',188)],'mixed','English','assembled-human-recordings')
    human('human_codeswitch_to_chinese',[('ascend',9)],'mixed','Chinese')

    base, text, origin=clips['minds-en-AU',0]
    for snr in (10,0):
        rng=np.random.default_rng(20261028)
        noise=lfilter([1],[1,-0.9],rng.standard_normal(len(base)))
        noise *= np.sqrt(np.mean(base**2)) / (np.sqrt(np.mean(noise**2))*10**(snr/20))
        add(f'stress_noise_{snr}db',base+noise,text,'en','Chinese','augmented-human-recording',[origin],
            [f'add deterministic colored noise at nominal whole-clip RMS SNR {snr} dB; peak normalize if needed'])
    add('stress_quiet_voice',base*0.05,text,'en','Chinese','augmented-human-recording',[origin],['multiply amplitude by 0.05 (-26 dB)'])
    delay=int(0.18*RATE)
    echo=np.pad(base,(0,delay));echo[delay:]+=base*0.55
    add('stress_echo',echo,text,'en','Chinese','augmented-human-recording',[origin],['add 180ms delayed copy at 0.55 amplitude'])
    fast=inputs/'fast.wav'
    convert(inputs/'minds-en-GB-3.wav',fast,'atempo=1.4')
    _, fast_text, fast_origin=clips['minds-en-GB',3]
    add('stress_fast_1_4x',read_audio(fast),fast_text,'en','Chinese','augmented-human-recording',[fast_origin],['ffmpeg atempo=1.4'])

    human('stress_voice_turn_taking',[('minds-en-AU',0),('minds-en-GB',0)],'en','Chinese','assembled-human-recordings',gap=0.25)
    other, other_text, other_origin=clips['ami-100',152]
    offset=int(1.2*RATE)
    mixture=np.zeros(max(len(base),offset+len(other)))
    mixture[:len(base)]+=base;mixture[offset:offset+len(other)]+=other
    add('stress_two_voices_overlap',mixture,text+' '+other_text,'en','Chinese','augmented-human-recordings',
        [origin,other_origin],['mix two different original recordings; second speaker starts at +1.2s'],
        unorderedReferences=[text,other_text])
    balanced=np.zeros(len(mixture))
    balanced[:len(base)] += base * (0.05 / np.sqrt(np.mean(base**2)))
    balanced[offset:offset+len(other)] += other * (0.05 / np.sqrt(np.mean(other**2)))
    add('stress_two_voices_overlap_balanced',balanced,text+' '+other_text,'en','Chinese','augmented-human-recordings',
        [origin,other_origin],['normalize both speakers to equal whole-clip RMS before overlapping; second starts at +1.2s'],
        unorderedReferences=[text,other_text])
    zh,zh_text,zh_origin=clips['aishell-500',504]
    add('stress_language_switch_and_silence',np.concatenate([base,np.zeros(RATE*6),zh]),text+' '+zh_text,
        'mixed','English','assembled-human-recordings',[origin,zh_origin],['6s silence between English and Mandarin voices'])

    long_keys=[];duration=0
    for key in [('libri',i) for i in range(14)]+[('libri-200',i) for i in range(200,221)]:
        long_keys.append(key);duration+=len(clips[key][0])/RATE+0.25
        if duration>=180:break
    human('stress_long_3min',long_keys,'en','Chinese','assembled-human-recordings',gap=0.25)
    tight_keys=[];duration=0
    for key in [('libri',i) for i in range(14)]:
        tight_keys.append(key);duration+=len(trim(clips[key][0]))/RATE
        if duration>=80:break
    tight=np.concatenate([trim(clips[key][0]) for key in tight_keys])
    tight_path=inputs/'tight.wav';write_audio(tight_path,tight)
    convert(tight_path,fast,'atempo=1.25')
    add('stress_continuous_fast_speech',read_audio(fast),' '.join(clips[k][1] for k in tight_keys),
        'en','Chinese','augmented-human-recordings',[clips[k][2] for k in tight_keys],
        ['trim outer silence retaining 50ms pre-roll/80ms tail; concatenate without added gaps; atempo=1.25'],drainBudgetSeconds=90)

    voice=trim(base)
    add('stress_eof_no_tail_silence',voice[:-1000],text,'en','Chinese','augmented-human-recording',[origin],['trim endpoint silence; end audio source without an added pause'],tailSilenceSeconds=0)
    rng=np.random.default_rng(20261028)
    add('stress_noise_without_speech',rng.standard_normal(RATE*4)*0.025,'','en','Chinese','generated-control',[],['deterministic noise only; expected zero speech'])
    spoken="I don't think [[slnc 1800]] we should ship today. We must wait until the security review is complete."
    aiff=inputs/'long-pause.aiff';wav=inputs/'long-pause.wav'
    subprocess.run(['say','-v','Samantha','-o',str(aiff),spoken],check=True)
    convert(aiff,wav)
    add('control_long_thinking_pause',read_audio(wav),re.sub(r'\[\[slnc \d+\]\]\s*','',spoken),
        'en','Chinese','synthetic-control',[],['Samantha TTS with explicit 1800ms pause after I do not think'])

    spoken=('Although the engineering team has already prepared the new release and the sales team would like us to launch it next Friday at two thirty in the afternoon, '
        'we should keep the current version running for all existing customers while the security team checks the revised authentication flow, '
        'the support team confirms that the migration guide explains how to restore the previous settings, '
        'and the finance team verifies that the approved budget is fifteen thousand dollars rather than fifty thousand dollars, '
        'because completing the implementation does not mean that we have permission to release it, '
        'and we must not announce that the problem has been resolved or mark the task as complete unless every required review has actually passed.')
    subprocess.run(['say','-v','Samantha','-r','160','-o',str(aiff),spoken],check=True)
    convert(aiff,wav)
    add('control_long_single_sentence',read_audio(wav),spoken,'en','Chinese','synthetic-control',[],
        ['one long sentence; nested conditions; negation and approval condition near the end; 160 words/minute'],drainBudgetSeconds=90)

    (root/'manifest.json').write_text(json.dumps(fixtures,ensure_ascii=False,indent=2))
    # Freeze a plan before running models; do not silently discard failures.
    plan=dict(case_count=len(fixtures),audio_seconds=sum(f['audioSeconds'] for f in fixtures),
        definitions={'raw_recording':'single public human recording',
                     'assembled_recordings':'real voices edited/concatenated, not an unedited real meeting',
                     'augmented_recording':'real voice with explicitly generated acoustic stress',
                     'synthetic_control':'controlled TTS/noise, not human evidence'},
        case_ids=[f['id'] for f in fixtures])
    (root/'test-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2))
    print(json.dumps(plan,ensure_ascii=False,indent=2))


def tokens(text, language):
    if language=='zh':return [c for c in text.casefold() if c.isalnum()]
    if language=='mixed':return re.findall(r'[\u3400-\u9fff]|[a-z0-9]+',text.casefold())
    return re.findall(r"[a-z0-9]+(?:'[a-z]+)?",text.casefold())


def edit_distance(a,b):
    row=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        nxt=[i]
        for j,y in enumerate(b,1):nxt.append(min(nxt[-1]+1,row[j]+1,row[j-1]+(x!=y)))
        row=nxt
    return row[-1]


def summarize(root, results):
    manifest={f['id']:f for f in json.loads((root/'manifest.json').read_text())}
    data=[r for r in map(json.loads,results.read_text().splitlines()) if r['kind']=='pipeline']
    output=[]
    for row in data:
        f=manifest[row['fixture']];ref=tokens(f['reference'],f['language']);hyp=tokens(row['source'],f['language'])
        output.append(dict(id=f['id'],category=f['category'],audioSeconds=row['audioSeconds'],
            recognition_error_rate=edit_distance(ref,hyp)/len(ref) if ref and not f.get('unorderedReferences') else None,
            metric='CER' if f['language']=='zh' else 'mixed-token error' if f['language']=='mixed' else 'WER',
            pipeline_completed=row.get('inputFinished') and row.get('captionsDrained') and not row.get('error'),
            readingViolations=row.get('readingViolations'),droppedSegments=row['droppedSegments'],
            captionQueue=row['maximumCaptionQueue'],firstCaptionMS=row.get('firstCaptionMS'),
            readingRatio=row.get('minimumReadingRatio'),error=row.get('error'),segments=row['segments'],
            drainAfterAudioS=max(0,row['completeMS']/1000-row['audioSeconds']),
            unexpectedSpeech=not ref and bool(hyp),reference=f['reference'],source=row['source'],translation=row['translation']))
    path=results.with_suffix('.summary.json');path.write_text(json.dumps(output,ensure_ascii=False,indent=2))
    for row in output:
        rate=row['recognition_error_rate']
        print(row['id'],row['pipeline_completed'],f'{rate:.1%}' if rate is not None else 'n/a',
              row['droppedSegments'],row['readingViolations'],row['error'])
    print('summary:',path)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    parser.add_argument('--summarize',type=Path)
    args=parser.parse_args()
    root=args.directory.resolve()
    if args.summarize:summarize(root,args.summarize.resolve())
    else:prepare(root)
