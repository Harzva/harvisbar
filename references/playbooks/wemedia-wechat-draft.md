# WeMedia WeChat Draft Playbook

This playbook is reference material for a Codex Conductor. It is not router
logic, and Harvis should not hard-code these stages as the only valid workflow.

## Goal

Turn an external article link, usually from WeChat, Zhihu, or CSDN, into a
verified WeChat draft-box article under:

`<wemedia-root>`

## Suggested Worker Roles

- `kimicode`: primary source-ingestion worker for `mp.weixin.qq.com` links. It
  should parse the external article, summarize source content, recover title and
  key points, discover article images, and extract paper/project links when
  direct Codex/curl extraction is weak or blocked.
- `codex`: plan the workflow, inspect local files, write artifacts, verify
  quality gates, and write `conductor_result.json`.
- `md2wechat`: upload images, call `create_draft`, and verify returned
  `media_id` with WeChat `draft/get` when UI verification is unavailable.
- `browser`: verify the draft box when API or local evidence is not enough.

## Orchestration Boundary

For WeChat links, Codex Conductor controls the workflow but should not treat
itself as the primary article-body scraper. The expected order is:

1. Ask `kimicode` to produce a source package under the material directory.
2. Have `codex` audit that package and turn it into local artifacts.
3. Download or verify article images first; if the source cites a paper or
   project, download the paper when available and extract useful figures.
4. Use `md2wechat` to upload images and create the draft.
5. Use `draft/get` API evidence to verify the draft box; `browser` UI proof is
   an optional operator-requested visual check.

If `kimicode` cannot produce usable source content, stop with
`source_fetch_blocked`. Do not create a WeChat draft from guessed, empty, or
unverified source material.

Use the `kimicode` worker command advertised in `worker-registry.json` instead
of hand-building a wrapper command. The Kimi worker must preserve the authenticated
user HOME because Kimi Code model/provider configuration lives there. In smoke
tests, a workspace-local HOME produced empty or invalid source packages.

## Suggested Artifacts

- `manifest.json`: source URL, title, author, publish time, extraction method,
  and fallback attempts.
- `kimi-source-package.md`: Kimi output with title/body summary, image
  candidates, and paper/project links.
- `kimi-source-status.json`: worker adapter status with exit code, output size,
  validation result, stdout/stderr paths, and explicit failure problems.
- `source.md` or `source.html`: extracted article content.
- `summary.md`: compact technical summary and rewrite notes.
- `article.md`: final WeChat Markdown.
- `draft.json`: payload used for `md2wechat create_draft`.
- `image-upload-map.json`: local image path or remote URL to WeChat image URL.
- `wechat-draft-api-proof.json`: sanitized WeChat `draft/get` proof when a
  draft `media_id` exists.
- `conductor_result.json`: final business result and artifact proof.

## Image Policy

Prefer original article images first. If the article cites a paper or project,
the conductor may download the paper and extract 2-4 useful figures with local
PDF tooling such as PyMuPDF or pdffcrop-style helpers.

The draft should not be accepted as complete when the image count is zero unless
the result clearly says why images could not be obtained.

## WeChat Draft Policy

`create_draft` is an allowed draft-box action. It is not a formal publish,
group-send, freepublish, deploy, push, or delete action.

The conductor must record the returned draft/media id when available. If no id
is returned, the result must say that the draft-box write was not proven.

After `create_draft` returns a media id, the conductor should run the local
`harvis_wechat_draft_verify.py` helper or equivalent registry verify command.
This writes sanitized `draft/get` evidence without storing or printing access
tokens, app secrets, cookies, or the full article body. API proof is the normal
completion proof for Harvis Lark smoke runs. Browser/UI proof or a draft-box
screenshot is optional and only needed when the operator explicitly asks for a
visual check.

## Quality Gates

- Final article has at least one usable image.
- WeChat image references are uploaded URLs, not local file paths.
- The ending removes source-tail text such as:
  - 文章来源
  - 来源公众号
  - 原文来自
  - 转载自
  - 本文来源于
- Source attribution is retained in local manifest or publish record, not as a
  copied original-account footer in the public article body.

## Failure Reporting

Failure should be specific and stage-like, for example:

- `source_fetch_blocked`: WeChat page required auth or captcha.
- `image_download_failed`: source image URLs were unavailable.
- `paper_not_found`: no public paper link was found.
- `draft_payload_missing`: article was generated but no draft JSON exists.
- `create_draft_failed`: md2wechat returned an error.
- `draft_box_unverified`: command exited successfully but no draft id or API
  proof was found.
- `wechat_draft_created`: `create_draft` returned a media id and `draft/get`
  verified it.

An exit code of 0 is not enough. The conductor result must prove business
success with artifacts.
