# codex-loop

`codex-loop` is a global PowerShell command that wraps `codex exec` and keeps retrying a goal until it is acquired.

You run it from any project folder:

```powershell
codex-loop "Find and validate a simple scalping strategy that averages 1+ trade/day with 1:1.5 risk reward and at least 55% win rate."
```

The wrapper turns your raw prompt into a short, structured goal, shows it for approval, then starts Codex. If Codex reports failure, the wrapper feeds the same goal plus the previous attempt history back into the next run.

## Features

- Global `codex-loop "prompt"` command.
- Goal refinement before the loop starts.
- Proceed, modify, or cancel prompt before spending real attempts.
- Default limit of 10 attempts.
- YOLO/full-access Codex execution by default.
- JSON result contract attached automatically to every Codex run.
- Accumulated attempt history passed into future attempts.
- Optional external verifier command.
- Compact, human-readable progress output.
- Verbose raw command trace available with `-ShowCommands`.
- Resume support with `-Resume`.

## Files

```text
codex-loop.ps1          Main PowerShell implementation
codex-loop.cmd          Windows command shim
README.md               Project overview
```

## Install

Copy both command files into a folder on your `PATH`.

For many Windows Codex/npm installs, the user-level command folder is:

```text
%APPDATA%\npm
```

Install manually:

```powershell
Copy-Item .\codex-loop.ps1 "$env:APPDATA\npm\codex-loop.ps1" -Force
Copy-Item .\codex-loop.cmd "$env:APPDATA\npm\codex-loop.cmd" -Force
```

After that, open a new terminal or run:

```powershell
codex-loop "your goal here"
```

## Basic Usage

Run from the project you want Codex to work on:

```powershell
codex-loop "Add tests for the API client and fix any bugs you find."
```

Run against a specific project:

```powershell
codex-loop `
  "Create a robust scalping strategy and validate it across BTC, ETH, and SOL." `
  -Project "C:\Path\To\Your\Project" `
  -MaxRuns 20
```

Skip the goal review step:

```powershell
codex-loop "Fix the failing tests" -SkipGoalReview
```

Use an external verifier:

```powershell
codex-loop `
  "Fix the project until all tests pass." `
  -SuccessCommand "python -m pytest" `
  -MaxRuns 10
```

Show the raw command trace:

```powershell
codex-loop "Investigate and fix the bug" -ShowCommands
```

## What The Output Looks Like

Default output is intentionally human-readable:

```text
Attempt 1/10
-------------
  Reading the project structure and current test setup.

  Inspected 8 items, ran 6 commands

  The first pass exposed two failing tests around path handling. I am tightening that logic and rerunning the focused suite.

  Edited 1 file, ran 2 commands

  Success: Fixed the failing tests and verified the suite passes.
```

Default mode hides individual shell commands and file reads. Use `-ShowCommands` if you need the raw trace for debugging.

## How Retry State Works

Each target project gets a local `.codex-loop` folder:

```text
.codex-loop/
  original-prompt.txt
  approved-goal.txt
  goal.md
  codex-result-schema.json
  history.json
  state.json
  runs/
    0001/
      codex-events.jsonl
      codex-result.json
      loop-result.json
```

Every new attempt receives:

- the approved goal,
- the required JSON result schema,
- the previous failures,
- what was already tried,
- files changed,
- verifier results,
- and the next suggested plan.

That is what prevents Codex from starting fresh each time.

## Success Rules

Without `-SuccessCommand`, success is based on Codex's final JSON:

```json
{
  "status": "success",
  "attempt_summary": "The requested work is complete and verified."
}
```

With `-SuccessCommand`, the verifier exit code decides the real result. Exit code `0` means success; anything else triggers the next attempt.

## Useful Options

```powershell
-Project <path>                 # defaults to current directory
-MaxRuns 20                     # number of Codex attempts; default is 10
-SuccessCommand <command>        # optional external verifier
-Model gpt-5.5                  # optional model override
-SkipGoalReview                 # use your prompt directly without approval
-AutoApproveGoal                # refine and print the goal, then proceed
-ShowJsonResult                 # print the raw loop-result JSON at the end
-ShowCommands                   # show raw shell command events
-Yolo:$false                    # disable YOLO mode
-FullAuto:$true                 # use --full-auto when YOLO is disabled
-Sandbox workspace-write        # used only when YOLO and FullAuto are disabled
-Resume                         # resume existing loop state
-SkipInitialCheck               # skip precheck verifier run
-StopAfterNoChangeRuns 2        # stop if failed attempts stop changing git diff
-MaxHistoryChars 60000          # cap retry history included in the next prompt
```

## Notes

By default, `codex-loop` runs Codex with:

```text
codex exec --dangerously-bypass-approvals-and-sandbox
```

That is intentional for autonomous project work, but it means Codex has full access inside the project environment. Use it only in folders where you are comfortable giving Codex that level of control.
