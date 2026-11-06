#!/usr/bin/env python3
"""Prepare synthetic EN/ZH fixtures and summarize Ora's signed-bundle replay results.

Run the bundle with --benchmark-api-local --mode api|local --manifest manifest.json
--output api.jsonl|local.jsonl --quality high --repeats 2, then use --summarize.
No microphone, account history, or API key is read by this script.
"""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import subprocess

CASES = [
    ('en_schedule', 'en', 'Chinese', "Let's move the design review to Thursday at two thirty in the afternoon.", '我们把设计评审改到周四下午两点半。'),
    ('en_numbers', 'en', 'Chinese', 'The budget is fifteen thousand dollars, not fifty thousand dollars.', '预算是一万五千美元，不是五万美元。'),
    ('en_action', 'en', 'Chinese', 'Please send the revised contract to Alice before noon tomorrow.', '请在明天中午之前把修改后的合同发给艾丽丝。'),
    ('en_technical', 'en', 'Chinese', 'We need to reduce latency without lowering recognition accuracy.', '我们需要在不降低识别准确率的前提下降低延迟。'),
    ('zh_schedule', 'zh', 'English', '我们把设计评审改到周四下午两点半，线上参加。', "Let's move the design review to Thursday at 2:30 p.m. and attend online."),
    ('zh_numbers', 'zh', 'English', '预算是一万五千美元，不是五万美元。', 'The budget is fifteen thousand US dollars, not fifty thousand.'),
    ('zh_action', 'zh', 'English', '请在明天中午之前，把修改后的合同发给艾丽丝。', 'Please send the revised contract to Alice before noon tomorrow.'),
    ('zh_negation', 'zh', 'English', '这个问题还没有解决，请不要把任务标记为完成。', 'This issue has not been resolved. Please do not mark the task as completed.'),
]


MEETING_CASES = [
    ('en_paused_negation', 'en', 'Chinese', "I don't think [[slnc 450]] we should ship today. We must wait until the security review is complete.", '我认为我们今天不应该发布，必须等到安全评审完成。'),
    ('en_paused_amount', 'en', 'Chinese', 'The budget is fifteen thousand dollars, [[slnc 450]] not fifty thousand dollars. Please do not approve the larger amount.', '预算是一万五千美元，不是五万美元，请不要批准较大的金额。'),
    ('zh_paused_condition', 'zh', 'English', '我们需要降低延迟，[[slnc 450]]但不能降低识别准确率。这个问题还没有解决，请不要把任务标记为完成。', 'We need to reduce latency without lowering recognition accuracy. This issue is not resolved; do not mark it complete.'),
    ('en_self_correction', 'en', 'Chinese', 'Schedule it for Thursday, [[slnc 450]] sorry, Friday at two thirty in the afternoon.', '安排在周四，不好意思，是周五下午两点半。'),
]


def prepare(root, meeting=False):
    audio = root / 'audio'
    audio.mkdir(parents=True, exist_ok=True)
    (root / '.gitignore').write_text('audio/\n', encoding='utf-8')
    manifest = []
    for case, language, target, spoken, translation in (MEETING_CASES if meeting else CASES):
        reference = re.sub(r'\[\[slnc \d+\]\]\s*', '', spoken)
        aiff = audio / (case + '.aiff')
        wav = audio / (case + '.wav')
        subprocess.run(['/usr/bin/say', '-v', 'Samantha' if language == 'en' else 'Tingting', '-o', str(aiff), spoken], check=True)
        subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
        aiff.unlink()
        manifest.append(dict(id=case, language=language, targetLanguage=target, reference=reference,
                             referenceTranslation=translation, audioPath=str(wav)))
    (root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Prepared {len(manifest)} synthetic fixtures in {root}')


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        nxt = [i]
        for j, right in enumerate(b, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j - 1] + (left != right)))
        row = nxt
    return row[-1]


def units(text, language):
    text = text.casefold()
    if language == 'en':
        return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text)
    return [ch for ch in text if ch.isalnum()]


def summarize(root):
    fixtures = {item['id']: item for item in json.loads((root / 'manifest.json').read_text())}
    result = {}
    for mode in ['api', 'local', 'hybrid']:
        path = root / (mode + '.jsonl')
        if not path.exists():
            continue
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        samples = [row for row in rows if row['kind'] == 'sample']
        successful = [row for row in samples if not row.get('error')]
        metrics = {}
        for key in ['asrMS', 'translationFirstTokenMS', 'translationTotalMS', 'firstTranslationMS', 'totalMS']:
            values = sorted(row[key] for row in successful if row.get(key) is not None)
            metrics[key] = dict(median=statistics.median(values), minimum=min(values), maximum=max(values),
                                p95=values[max(0, math.ceil(len(values) * 0.95) - 1)]) if values else None
        errors = {}
        for language in ['en', 'zh']:
            subset = [row for row in successful if fixtures[row['fixture']]['language'] == language]
            edits = total = 0
            for row in subset:
                ref = units(row['reference'], language)
                edits += distance(ref, units(row['recognized'], language))
                total += len(ref)
            errors['WER' if language == 'en' else 'CER'] = dict(edits=edits, reference_units=total,
                                                              rate=edits / total if total else None)
        result[mode] = dict(metadata=next((row for row in rows if row['kind'] == 'metadata'), None),
                            warmup=next((row for row in rows if row['kind'] == 'warmup'), None),
                            attempted=len(samples), succeeded=len(successful), metrics_ms=metrics,
                            recognition_error_rates=errors)
    audit_path = root / 'semantic-audit.json'
    if audit_path.exists():
        audit = json.loads(audit_path.read_text())
        for mode, summary in result.items():
            reviewed = [item for item in audit if item['mode'] == mode]
            summary['critical_semantics_review'] = dict(
                passed=sum(item['critical_semantics_pass'] for item in reviewed), total=len(reviewed),
                method='Assistant review against predefined rubric.json; not an independent human-rated accuracy benchmark.')
    (root / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--summarize', action='store_true')
    parser.add_argument('--meeting', action='store_true', help='Generate continuous speech with 450ms mid-sentence pauses and corrections.')
    args = parser.parse_args()
    directory = args.directory.resolve()
    if args.summarize:
        summarize(directory)
    else:
        prepare(directory, meeting=args.meeting)
