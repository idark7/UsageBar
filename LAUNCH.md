# Launch checklist

## 0. Ship (10 min)
```bash
gh auth login
gh repo create idark7/UsageBar --public --source=. --push
git checkout main && git merge v3-rewrite && git push
git tag v3.0.0 && git push --tags        # CI builds + attaches the DMG
```
Then: `shasum -a 256 build/UsageBar-3.0.0.dmg` → paste into `Casks/usagebar.rb`, and create a tap repo
`idark7/homebrew-tap` containing `Casks/usagebar.rb` so people can `brew install idark7/tap/usagebar`.

## 1. Hero GIF (5 min)
`brew install ffmpeg && scripts/record-demo.sh`, commit `demo.gif`, replace the TODO in README.md.
The GIF is the whole pitch — show the pill turning red and the "Claude Code at 80%" notification if you can.

## 2. Repo polish
- Topics: `claude-code`, `codex`, `macos`, `menubar`, `swift`, `rate-limit`
- Description: "Claude Code + Codex usage limits in your macOS menu bar. Zero setup."
- Pin the demo GIF as the social preview image (Settings → Social preview)

## 3. Post (same day, in this order)
**X / Twitter** (tag @AnthropicAI @OpenAIDevs, attach the GIF):
> I kept slamming into Claude Code's 5-hour limit mid-task, so I built a menu bar app that shows it live.
> Claude Code + Codex, zero setup, notifies you at 80%. Free & open source, single Swift binary.
> ⬇️ github.com/idark7/UsageBar

**Hacker News** — *Show HN: UsageBar – Claude Code and Codex rate limits in the macOS menu bar*
> I use Claude Code on a Pro plan and the 5-hour window kept catching me by surprise. `/usage` works but you
> have to remember to run it. UsageBar reads the usage samples the Claude desktop app already writes locally
> (no token, no API calls), plus Codex's session logs, and shows both in the menu bar with notifications at
> 80/95% and a countdown to reset. Native Swift, ~300 KB, MIT. Feedback on the detection heuristics welcome —
> especially from Max/Team plan users, I've only tested on Pro.

**Reddit** — r/ClaudeAI, r/ClaudeCode, r/macapps, r/OpenAI (post GIF as image, link in comments; ask a question
in the title: "Anyone else keep hitting the 5-hour limit without warning? I made a menu bar app for it")

**Anthropic Discord** #claude-code-showcase, OpenAI Developer Forum → Codex category.

## 4. Follow-ups that keep it spreading
- Reply to every "does it support X?" with an issue link — Gemini CLI and Cursor are the obvious next providers.
- Notarize ($99 Apple Developer) as soon as there's traction; the right-click-to-open step loses half of users.
- Add a `/usagebar` mention to awesome-claude-code and awesome-mac lists via PR.
