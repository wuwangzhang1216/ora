#!/usr/bin/env python3
"""Render every replay's reference, recognized text, translation and timings.

Semantic findings are explicitly supplied in case-review.json, never inferred
from HTTP success or WER alone. The raw replay JSONL remains the evidence.
"""
import argparse
import csv
import json
from pathlib import Path

from benchmark_multiscenario import edit_distance, tokens

LABELS = {
 'control_long_thinking_pause':'1.8 秒思考停顿与否定',
 'control_long_single_sentence':'38 秒嵌套条件长句',
 'control_69sec_single_sentence':'69 秒嵌套条件单句压力对照',
 'human_en_reader_a':'真实英文朗读 A：送花与回礼',
 'human_en_reader_b':'真实英文朗读 B：因果与转折',
 'human_zh_voice_a':'真实普通话：薪酬、福利与缺失指代',
 'human_zh_voice_b':'真实普通话：公司名与最大规模',
 'human_australian_english':'澳大利亚英语语料：电费付款',
 'human_british_english':'英国英语语料：技术问题与回电',
 'human_meeting_menus':'AMI 自然会议：菜单和复选框',
 'human_meeting_weekend':'AMI 自然会议：周末工作与同步',
 'human_codeswitch_major':'ASCEND 中英混说：专业名，译英文',
 'human_codeswitch_jobs':'ASCEND 中英混说：求职与城市机会',
 'human_codeswitch_to_chinese':'ASCEND 中英混说：同一音频译中文',
 'stress_noise_10db':'真实人声＋10 dB 有色噪声',
 'stress_noise_0db':'真实人声＋0 dB 有色噪声',
 'stress_quiet_voice':'真实人声衰减至 5% 音量',
 'stress_echo':'真实人声＋180 ms 回声',
 'stress_fast_1_4x':'真实人声 1.4 倍语速',
 'stress_voice_turn_taking':'不同人声紧接轮流讲话',
 'stress_two_voices_overlap':'不同人声重叠，原始音量相差约 18 dB',
 'stress_two_voices_overlap_balanced':'不同人声等 RMS 音量重叠',
 'stress_language_switch_and_silence':'英语→6 秒静音→普通话',
 'stress_eof_no_tail_silence':'语音流直接结束，没有尾静音',
 'stress_noise_without_speech':'只有噪声，没有讲话',
 'stress_continuous_fast_speech':'67 秒快速连读与连续切片',
 'stress_long_3min':'约 3 分钟真实人声长文',
}


def read_rows(path):
    if not path.exists(): return []
    rows=[]
    for line in path.read_text().splitlines():
        if not line.strip(): continue
        row=json.loads(line)
        if row['kind']=='pipeline': rows.append(row)
    return rows


def quote(text):
    return '\n'.join('> '+line for line in (text or '（无）').splitlines())


def seconds(ms):
    return '无字幕' if ms is None else f'{ms/1000:.2f} 秒'


def rate(fixture,row):
    if fixture.get('unorderedReferences'): return '不适用：重叠语音没有唯一词序'
    reference=tokens(fixture['reference'],fixture['language'])
    actual=tokens(row['source'],fixture['language'])
    if not reference:return '预期无讲话；'+('出现了文本' if actual else '没有生成文本')
    name='CER' if fixture['language']=='zh' else '混合词/字编辑差异' if fixture['language']=='mixed' else 'WER'
    return f'{name} {edit_distance(reference,actual)/len(reference):.1%}'


def metrics(row):
    after=max(0,row['completeMS']/1000-row['audioSeconds'])
    return f"首条译文 {seconds(row.get('firstCaptionMS'))}；音频结束后 {after:.2f} 秒；丢段 {row['droppedSegments']}；阅读不足 {row.get('readingViolations','未采集')} 次"


def render(root,require_complete):
    fixtures=json.loads((root/'final-manifest.json').read_text())
    original_count=len(fixtures)
    if (root/'extra-long-sentence-manifest.json').exists():
        fixtures+=json.loads((root/'extra-long-sentence-manifest.json').read_text())
    final=read_rows(root/'final.jsonl');by_id={r['fixture']:r for r in final}
    before_boundary=dict(by_id)
    boundary={r['fixture']:r for r in read_rows(root/'long-boundary-retest.jsonl')}
    by_id.update(boundary)
    extra=read_rows(root/'extra-long-sentence.jsonl')
    by_id.update({r['fixture']:r for r in extra})
    before_language=dict(by_id)
    language_hybrid={r['fixture']:r for r in read_rows(root/'language-hybrid-retest.jsonl')}
    language_api={r['fixture']:r for r in read_rows(root/'language-api-retest.jsonl')}
    by_id.update(language_hybrid)
    reviews=json.loads((root/'case-review.json').read_text()) if (root/'case-review.json').exists() else {}
    baseline={r['fixture']:r for r in read_rows(root/'human-and-stress.jsonl')}
    baseline.update({r['fixture']:r for r in read_rows(root/'controls-before.jsonl')})
    cloud={r['fixture']:r for r in read_rows(root/'api-recognition-check.jsonl')}
    model={r['fixture']:r for r in read_rows(root/'translation-model-check.jsonl')}
    cloud_followup={r['fixture']:r for r in read_rows(root/'api-followup.jsonl')}
    model_followup={r['fixture']:r for r in read_rows(root/'model-failure-retest.jsonl')}
    if require_complete:
        assert len(final)==original_count and len(by_id)==len(fixtures) and len(extra)==1, 'Replay rows are missing or duplicated.'
        assert len(cloud)==4 and len(model)==4, 'Differential replays are not finished.'
        assert len(boundary)==4 and len(cloud_followup)==2 and len(model_followup)==2, 'Follow-up replays are not finished.'
        assert len(language_hybrid)==4 and len(language_api)==1, 'Language correction replays are not finished.'
        assert all(reviews.get(f['id'],{}).get('status') not in (None,'待审阅') for f in fixtures), 'Some semantic cases are not reviewed.'
    lines=['# Ora 多场景、长文与长句实测', '',
        '最新字幕体验收敛、长句首显和长文积压复测见 [字幕体验记录](experience.md)。本页保留此前 27 场景的完整原文、译文与模型输出观察，不把内容评分当作 Ora 的验收门槛。', '',
        f"状态：已完成 {len(final)+len(extra)}/{len(fixtures)} 个场景（含追加的 69 秒单句）；边界修复复测 {len(boundary)}/4；另有 API 识别对照 {len(cloud)}/4、翻译模型对照 {len(model)}/4、后续 API/模型复测 {len(cloud_followup)+len(model_followup)}/4。日期：2026-10-28（Toronto）。",'',
        f"目标语言补丁复测：本地识别 {len(language_hybrid)}/4、API 识别 {len(language_api)}/1。",'',
        '主测试为真实模型按音频实际时长回放：Silero VAD → 本地 Qwen3-ASR-1.7B → RealRouter gpt-6-luna → 实际字幕调度器。包含公开真人录音、清楚标明的录音加工，以及三个合成语音对照（其中一个为同一句的减速版本）。不是实际加入 Zoom 通话或麦克风现场采集。', '',
        '模型名称是 RealRouter 返回/接受的配置标识；没有独立核验代理后面的实际供应商和权重版本。所有延迟仅代表这台电脑与这个 API 实例。', '',
        '**验收范围：Ora 的字幕体验。** 只以出字幕时机、分块完整、显示稳定、重复播放、积压和阅读时间评价 Ora。下面仍保留每条原文、译文与内容问题，但模型的词义和措辞质量不作为 Ora 的验收门槛，也不据此继续扩展模型选型或提示调优。', '',
        '## 本轮修复', '',
        '- 未说完的表达（如 I don’t think）允许额外等待至 2.4 秒，避免长思考停顿后丢失否定。',
        '- 15 秒声学切片不再等于翻译句子的边界；使用独立的 45 秒语义阈值，在后续声学边界兜底提交。38 秒句子可整体重新识别。',
        '- 到长文阈值时优先找前后识别共同确认的完整句末，携带 1 秒音频交叠到下一段，仅对这一人工交叠去重；找不到可信句末时仍有内存上限兜底。',
        '- 定稿原文若只在已确认完整句子后追加内容，复用那部分译文，只翻译新增内容；原文真正改写时允许重新翻译。',
        '- 长音频识别和翻译采用有上限的动态输出 token 预算，避免末尾条件被固定小预算截断。',
        '- 可见译文被修正时重新获得完整阅读时间；原文的小改动不重置稳定译文计时。',
        '- 强化提示要求保留不明确的代词及未完成语气。定稿携带已完成草稿作为措辞参考，同时明确新原文优先；模型仍可能不遵守，不能把提示修改当成语义保证。',
        '- 有限流结束等待全部推理及字幕排队；无尾静音场景实际使用零补静音。新会话重置 VAD 循环状态。', '',
        '- 翻译失败或空响应明确记录错误，并立即保存已识别原文为未完成记录，避免空结果被误认为正常完成。', '',
        '- 针对含中文且目标为中文的请求补充同语言输出约束；避免中英混说被模型习惯性改成英文。该提示不改变英文原文的请求。', '',
        '## 指标和判定', '',
        '- 首条译文：回放启动到第一条可读主译文，不是句子结束后的模型延迟。',
        '- 结束后等待：原始音频文件结束到推理完成且全部字幕读完；通常包含测试用的 2 秒尾静音，EOF 场景为零。',
        '- 阅读不足：按约 3 英文词/秒、6 个中日韩字符/秒的既定预算检查，容许 5% 计时误差。不是独立用户理解度评分。',
        '- 草稿修订不按一页已经读完计算；“阅读不足 0”不能证明每次瞬间出现的草稿都完整读完，或用户不会被修订打断。原始 cueUpdates 保留实际修订轨迹。',
        '- WER/CER 是与公开参考文本的编辑差异，仅归一大小写和标点；填充词、缩写及参考转写不规范都会影响它，不能直接当成关键语义错误率。',
        '- 长文采用明示的 90/120 秒结束后读取预算，让实际队列读完。提高测试预算不是产品提速：实际等待时间照实列出，超过旧 45 秒预算仍标明。',
        '- “推理完成”不代表“翻译正确”；每个场景的语义结论和未解决问题单列。语义审阅由助手完成，未做独立人工盲评。', '',
        '- 每份最终记录每个输入回放一次；另有列明的修复前后及模型对照。没有把这些单次延迟当作 P95，也没有测定多次运行的语义稳定性。', '',
        '- 下表长句、67 秒、3 分钟及求职场景使用边界修复后的复测；混说译中文、AMI 菜单、两组重叠人声使用目标语言补丁复测。其他场景使用之前模型/读时修复版本的实测，没有声称所有场景都在最后构建上重新回放。各版本原始文件均保留。', '',
        '## 全场景结果', '',
        '| 场景 | 音频 | 首条译文 | 音频结束后等待 | 内容观察（不是 Ora 验收） |',
        '|---|---:|---:|---:|---|']
    for f in fixtures:
        identifier=f['id'];row=by_id.get(identifier);review=reviews.get(identifier,{})
        if row:
            after=max(0,row['completeMS']/1000-row['audioSeconds'])
            lines.append(f"| [{LABELS[identifier]}](#{identifier.replace('_','-')}) | {row['audioSeconds']:.2f}s | {seconds(row.get('firstCaptionMS'))} | {after:.2f}s | {review.get('status','待审阅')} |")
        else:lines.append(f"| {LABELS[identifier]} | {f['audioSeconds']:.2f}s | — | — | 测试中 |")
    for i,f in enumerate(fixtures,1):
        identifier=f['id'];row=by_id.get(identifier);review=reviews.get(identifier,{})
        lines+=['',f'<a id="{identifier.replace("_","-")}"></a>',f'## {i:02d} · {LABELS[identifier]}', '',
            f"类型：`{f['category']}`。输入时长 {f['audioSeconds']:.2f} 秒。",'',
            '**原始参考文本**','',quote(f['reference']),'']
        if not row:lines+=['测试中。'];continue
        lines+=['**实际识别文本**','',quote(row['source']),'', '**最终译文**','',quote(row['translation']),'',
            '**延迟与运行记录**','',metrics(row)+f"；总用时 {row['completeMS']/1000:.2f} 秒。",'',
            f"{rate(f,row)}。最终片段数 {row['segments']}；推理全部结束 {row.get('inputFinished')}；字幕全部读完 {row.get('captionsDrained')}；测试读取预算 {row.get('drainBudgetSeconds',45):g} 秒。",'',
            '**内容观察、原因及风险（与字幕体验验收分开）**','',review.get('status','待审阅')+'：'+review.get('reason','尚未完成语义审阅。')]
        if row.get('error'):lines+=['',f"运行错误：{row['error']}"]
        if row['segments']>1:
            lines+=['','**实际定稿边界**','']
            for segment in row['segmentResults']:
                lines += [f"定稿于回放后 {segment['finishedMS']/1000:.2f} 秒：",'',quote(segment['source']),'',quote(segment['translation']),'']
        if identifier in boundary:
            previous=before_boundary[identifier]
            lines+=['','**最后边界修复前的同音频记录**','',metrics(previous),'',quote(previous['translation'])]
        if identifier in language_hybrid:
            previous=before_language[identifier]
            lines+=['','**目标语言补丁前的主场景记录**','',metrics(previous),'',quote(previous['translation'])]
        if identifier in baseline:
            before=baseline[identifier]
            lines+=['','**修复前记录**','',metrics(before)+('；'+before['error'] if before.get('error') else ''),
                '',quote(before['translation'])]
        for title,alternative in [('API 识别＋API 翻译对照',cloud),('本地识别＋gpt-6-sol 翻译对照',model),
                                  ('API 识别后续复测',cloud_followup),('gpt-6-sol 失败场景复测',model_followup)]:
            if identifier in alternative:
                other=alternative[identifier]
                lines+=['',f'**{title}**','',metrics(other),'','识别：',quote(other['source']),'','译文：',quote(other['translation'])]
                if other.get('error'):lines+=['',f"运行错误：{other['error']}"]
                if not other['source'] and other.get('sourceUpdates'):
                    lines+=['','旧版没有保存定稿；最后可见的识别草稿：',quote(other['sourceUpdates'][-1]['text'])]
        if identifier in language_api:
            other=language_api[identifier]
            lines+=['','**目标语言补丁后的 API 识别复测**','',metrics(other),'','识别：',quote(other['source']),'','译文：',quote(other['translation'])]
        if review.get('differential_note'):lines+=['',review['differential_note']]
        lines+=['','**来源与加工**','']
        for origin in f['origins']:
            lines.append(f"- [{origin['dataset']}]({origin['url']})，{origin['config']}/{origin['split']}，row {origin['row']}，ID `{origin['source_id']}`，{origin['license']}。")
        for transform in f.get('transforms',[]):lines.append('- '+transform)
        if not f['origins']:lines.append('- 本地生成对照音频。')
        lines+=['',f"输入 SHA-256：`{f['sha256']}`。"]
    lines+=['','## 原始证据与适用范围','',
        '- [最终主测试 JSONL](final.jsonl)、[全部输入及来源](final-manifest.json)、[语义逐项审阅](case-review.json)。',
        '- [边界修复后复测](long-boundary-retest.jsonl)、[API 后续复测](api-followup.jsonl)、[模型失败复测](model-failure-retest.jsonl)。',
        '- [追加 69 秒长句原始记录](extra-long-sentence.jsonl)、[追加长句来源与加工](extra-long-sentence-manifest.json)。',
        '- [目标语言补丁本地识别复测](language-hybrid-retest.jsonl)、[同补丁 API 识别复测](language-api-retest.jsonl)。',
        '- [逐场汇总 CSV](scenario-results.csv)、[构建和测试来源](run-provenance.json)。CSV 包含完整参考、识别、译文、延迟、结论及失败原因。',
        '- [最初长句失败](controls-before.jsonl)、[第一次语义修复复测](controls-after.jsonl)、[中间人声及压力测试](human-and-stress.jsonl)。',
        '- [云端识别对照](api-recognition-check.jsonl)、[另一个翻译模型对照](translation-model-check.jsonl)。对照只覆盖各自列明场景，不能推断全部场景都会改善。',
        '- 语料背景：[LibriSpeech / OpenSLR](https://www.openslr.org/12)、[AMI](https://huggingface.co/datasets/edinburghcstr/ami)、[AISHELL / OpenSLR](https://www.openslr.org/33/)、[ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)、[MINDS-14](https://huggingface.co/datasets/PolyAI/minds14)。',
        '- 原始/加工音频在 inputs/ 中，已忽略 Git；没有采集用户麦克风、系统音频或真实会议历史。主测试只上传已识别文本和上下文；API 识别对照明确上传这几条公开音频。',
        '- 未覆盖实际 Zoom 通话闭环、真实远场房间、多名远端同时讲话的整场会议或独立人工可理解性测评。生成噪声、单次回声与人声拼接不能冒充真实现场录音。',
        '- 长文回放包：`macos/Ora/.app/Ora Long Boundary Retest.app`；最终交付和目标语言复测包 `Ora Multiscenario Tested.app`。后者另加翻译失败状态文字和同语言输出提示。测试没有自动切换已安装应用或用户配置。', '']
    (root/'report.md').write_text('\n'.join(lines))
    columns=['id','scenario','category','audio_seconds','reference','recognized_source','translation',
             'first_caption_seconds','inference_after_audio_seconds','all_read_after_audio_seconds',
             'reading_violations','input_finished','captions_drained','runtime_error','review_status','failure_or_risk','evidence_file']
    with (root/'scenario-results.csv').open('w',newline='',encoding='utf-8-sig') as file:
        writer=csv.DictWriter(file,fieldnames=columns);writer.writeheader()
        for f in fixtures:
            identifier=f['id'];row=by_id.get(identifier)
            if not row:continue
            review=reviews.get(identifier,{})
            evidence='language-hybrid-retest.jsonl' if identifier in language_hybrid else 'extra-long-sentence.jsonl' if identifier=='control_69sec_single_sentence' else 'long-boundary-retest.jsonl' if identifier in boundary else 'final.jsonl'
            writer.writerow(dict(id=identifier,scenario=LABELS[identifier],category=f['category'],
                audio_seconds=row['audioSeconds'],reference=f['reference'],recognized_source=row['source'],
                translation=row['translation'],first_caption_seconds=None if row.get('firstCaptionMS') is None else round(row['firstCaptionMS']/1000,3),
                inference_after_audio_seconds=None if row.get('inferenceFinishedMS') is None else round(max(0,row['inferenceFinishedMS']/1000-row['audioSeconds']),3),
                all_read_after_audio_seconds=round(max(0,row['completeMS']/1000-row['audioSeconds']),3),
                reading_violations=row.get('readingViolations'),input_finished=row.get('inputFinished'),
                captions_drained=row.get('captionsDrained'),runtime_error=row.get('error'),
                review_status=review.get('status'),failure_or_risk=review.get('reason'),evidence_file=evidence))
    print(root/'report.md')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    parser.add_argument('--require-complete',action='store_true')
    args=parser.parse_args()
    render(args.directory.resolve(),args.require_complete)
