# Branch Protection & Approval Workflow — Setup and Access Guide

## Core Principle

**A merge into `qa`, `uat`, or `main` is only possible after a Designated Approver has reviewed and approved the pull request.** No one else — regardless of their role or how long they've worked on the change — can complete a merge on their own. Everyone else can freely open pull requests; only the Designated Approver's sign-off unlocks the merge button, and only accounts in the approver group can actually click it.

This is achieved with three GitHub features working together:

- **Teams** — a named group holding the people allowed to approve.
- **`CODEOWNERS`** — a file that tells GitHub who "owns" (must review) changes to a branch.
- **Rulesets** — branch-level rules that require a pull request, require that code-owner review, and block direct pushes.
- **Repository permission level** — the actual mechanism that stops a non-approver from clicking merge even after approval, since GitHub always allows anyone with Write access to complete an already-approved merge.

---

## PART 1 — Environment Setup (do this once, as the org/repo admin)

### 1.1 Create the approver team

1. Go to `github.com/orgs/<your-org>/teams` → **New team**
2. Name it `release-approvers`
3. On the team page → **Members** → add the person/people who will approve merges
4. _(Optional, only if production needs a separate, smaller approval circle)_ repeat to create a second team, e.g. `prod-access`, with a subset of the same people or different ones

### 1.2 Give the team repo access

1. Team page → **Repositories** → **Add repository** → select your repo → role **Write**
2. A team must have at least Write access to be usable as a code owner — team membership alone isn't enough

### 1.3 Add `CODEOWNERS` to the repo

Create `.github/CODEOWNERS` on every protected branch (`qa`, `uat`, `main`) with this content:

```
* @<your-org>/release-approvers
```

Important: GitHub reads `CODEOWNERS` from **the target branch of the pull request**, not the source branch. If you want a stricter, separate approver group for `main` specifically, give `main`'s copy different content (e.g. `* @<your-org>/prod-access`) — but know that this causes a **guaranteed merge conflict on every future `uat → main` promotion**, since the file will always differ between the two branches. See the Troubleshooting section for how to handle that if you go this route. The simpler, lower-maintenance option is to keep the same content on all three branches.

### 1.4 Create the branch ruleset

1. Repo → **Settings → Rules → Rulesets → New ruleset → New branch ruleset**
2. Name it (e.g. `require-release-approval`)
3. **Enforcement status:** Active
4. **Target branches:** add `qa`, `uat`, `main` as include patterns
5. Under **Rules**, enable:
   - **Require a pull request before merging**
     - Required approvals: `1`
     - **Require review from Code Owners: ON**
     - Dismiss stale approvals on new commits: recommended ON
   - **Restrict deletions**
   - **Block force pushes**
6. **Bypass list:** leave empty — this is what makes "nobody bypasses, not even admins" actually true
7. **Create**

### 1.5 Lower the org-wide permission floor

This is the step that makes the approver restriction actually stick, not just gate timing:

1. `github.com/organizations/<your-org>/settings/member_privileges`
2. **Base permissions** — if set to Write or higher, change it to **Read**. This is a floor applied to every member for every repo in the org; nothing at the repo level can override it upward or downward per-repo.

⚠️ This affects every repo in the org, not just this one. If other repos need to stay open-Write for everyone, that's the tradeoff of this step — there's no per-repo exception to a base permission.

### 1.6 Clean up the repo's own collaborator list

1. Repo → **Settings → Collaborators and teams**
2. Any individual or team listed with Write/Maintain/Admin that is **not** `release-approvers` (or `prod-access`) → change to **Read**, or remove
3. Confirm `release-approvers`/`prod-access` still show Write

### 1.7 Confirm forking is enabled

Since non-approvers can no longer push branches directly, they need to fork to contribute at all:

1. Org → Settings → Member privileges → confirm repository forking isn't disabled
2. Repo → Settings → General → Features → confirm "Allow forking" is checked

### 1.8 Verify the whole setup

1. Have someone **not** in `release-approvers` try the full flow (fork → branch → PR) and confirm the merge button stays disabled for them even after approval
2. Have a `release-approvers` member approve and merge the same PR, and confirm it goes through

---

## PART 2 — Access Enablement Document: FOR USERS (everyone not in the approver team)

### What changed

You can no longer push branches directly to this repository, and you cannot merge a pull request yourself — even one that's already been approved. Your workflow is now:

### Step-by-step

1. **Fork the repository** — on the repo's GitHub page, click **Fork** (top right), creating your own copy under your account
2. **Clone your fork** locally:
   ```
   git clone https://github.com/<your-username>/<repo>.git
   ```
3. **Make your changes** on a new branch in your fork:
   ```
   git checkout -b my-change
   # make your edits
   git add .
   git commit -m "describe your change"
   git push origin my-change
   ```
4. **Open a pull request** from your fork's branch into the upstream repo's `qa` (or `uat`/`main`, depending on what you're changing) — GitHub shows a "Compare & pull request" button automatically after your push, or use **New pull request** on the upstream repo
5. **Wait for review** — the PR will show "Review required from Code Owners" until a Designated Approver reviews it
6. **Once approved**, the PR is ready to merge — but the merge button will stay disabled or absent for your account. **This is expected.** Let the Designated Approver know it's ready; they complete the actual merge.

### What you'll see if something's blocked

- **"Merging is blocked / Waiting on code owner review"** — normal, means no approver has reviewed yet
- **Merge button greyed out even after approval** — normal, means you don't have merge rights; ping the approver
- **You cannot approve your own PR** — GitHub blocks this outright regardless of team membership; if you're also an approver, someone else needs to review your own PRs

---

## PART 3 — Access Enablement Document: FOR THE APPROVER (Designated Approver / `release-approvers` team member)

### Your role

You are the sole gate for every merge into `qa`, `uat`, and `main`. Nothing merges without your review, and (per the repo permission setup) you're also one of the few accounts able to actually complete a merge once it's approved.

### Reviewing a pull request

1. Open the PR → click the **Files changed** tab
2. Review the diff
3. Top-right, click **Review changes**
4. Select **Approve** (or **Request changes** if it's not ready), optionally add a comment
5. Click **Submit review**

### Merging

1. Once your approval is submitted and any other required checks pass, the **Merge pull request** button becomes active
2. Click it, confirm, and the merge completes

### Things to know

- **You cannot approve your own pull request.** If you personally opened a PR, a second approver (or a second account) must review it — there is no workaround for this in GitHub.
- **Approving is not the same as merging.** Submitting an "Approve" review unlocks the button; you (or another approver-permission account) still need to click merge separately.
- If a promotion PR (e.g. `uat → main`) shows a conflict specifically in `.github/CODEOWNERS`, see Troubleshooting below before resolving it — the naive fix can silently break the setup.

---

## Troubleshooting / Things That Bite Later

- **A team reference in `CODEOWNERS` with a typo (e.g. `prod-acccess` instead of `prod-access`) fails silently** — GitHub doesn't error, it just never matches anyone, quietly defeating the review requirement. If reviews aren't being requested as expected, check the exact spelling against the team's actual slug first.
- **`CODEOWNERS` merge conflicts on promotion PRs** — only happens if you deliberately gave different branches different `CODEOWNERS` content (see 1.3). If you did, resolve the conflict on a disposable branch, not the real source branch:
  ```
  git checkout -b promote-fix origin/uat
  git merge origin/main
  git checkout --theirs .github/CODEOWNERS
  git add .github/CODEOWNERS
  git commit
  git push origin promote-fix
  ```
  Then open the promotion PR from `promote-fix` instead of `uat` directly, so `uat`'s own `CODEOWNERS` is never overwritten.
- **Org base permissions override everything at the repo level.** If non-approvers can still merge despite this whole setup, check Step 1.5 first — a Write-or-higher org base permission silently grants that access back to everyone, regardless of what's configured per-repo.
- **A ruleset with an empty bypass list blocks direct pushes for everyone, including admins.** This is intentional and correct — if you ever need an emergency escape hatch, that means deliberately adding a specific account to the bypass list, not assuming admin status grants one.
