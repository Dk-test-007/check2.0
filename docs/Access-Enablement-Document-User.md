ACCESS ENABLEMENT DOCUMENT — REPOSITORY USER

Applies to: any contributor working in a private GitHub repository under a
GitHub Organization, where merges into protected branches require approval
from a Designated Approver.

Example environment referenced throughout: Organization "Dk-test-007",
repository "check2.0", protected branches "qa", "uat", "main". Replace these
with your own organization/repository/branch names as needed.

1. INTRODUCTION

1.1 Purpose

This document explains how a normal repository user works inside a
repository that requires Pull Request approval before any change reaches a
protected branch. It does not require any GitHub setup knowledge — that is
covered in the separate "Access Enablement Document — Designated Approver,"
which also covers administrator responsibilities.

1.2 Why Pull Request approval is required

Protected branches (in this environment: qa, uat, main) represent shared,
promoted, or production-facing states of the codebase. To prevent an
unreviewed or unintended change from reaching one of these branches, GitHub
is configured so that:

- No one can push directly to a protected branch.
- Every change must go through a Pull Request.
- A Pull Request cannot be merged until a specific, designated person (the
  "Designated Approver") has reviewed and approved it.

1.3 Contributor vs. Designated Approver

- A Contributor (User) can create branches, push changes, and open Pull
  Requests. A Contributor cannot merge a Pull Request, even one that has
  already been approved.
- The Designated Approver reviews Pull Requests, approves or requests
  changes, and is the only account authorized to complete the merge.

1.4 Intended workflow

User creates branch
-> User makes changes
-> User pushes branch
-> User creates Pull Request
-> Designated Approver reviews
-> Designated Approver approves
-> Pull Request becomes mergeable
-> Designated Approver (or another authorized merger) merges the Pull
Request

1.5 What happens in specific situations

- PR is approved: the "Merge" option becomes available to the Designated
  Approver. It does not become available to the Contributor who opened it.
- PR is rejected / changes requested: the Contributor must push additional
  commits addressing the feedback. The PR returns to "pending review."
- PR is updated after approval: depending on configuration, a prior
  approval may be automatically dismissed and re-review required (see
  section 8 of the Approver document for the exact setting). Assume a new
  review may be required after any new push unless told otherwise.
- PR has merge conflicts: GitHub will display "This branch has conflicts
  that must be resolved." The Contributor is expected to resolve these
  locally (see section 5) and push the resolution.
- Required checks fail: the PR cannot be merged until the checks pass
  again. Push a fix and wait for the checks to re-run.
- An unauthorized user (a Contributor) attempts to merge: the Merge button
  will be disabled, greyed out, or entirely hidden for their account, even
  after approval. This is expected and correct.
- An unauthorized user attempts to push directly to a protected branch:
  the push is rejected outright with an error similar to:
  "Changes must be made through a pull request."
  This is expected and correct. Use a Pull Request instead.

2. HOW YOU RECEIVE ACCESS

2.1 Organization / repository invitation

You will receive access in one of two ways, depending on how this
environment is configured:

a) Direct collaborator access: you are added to the repository (or a
GitHub Team with access to it) with a specific role, most commonly
"Read" in this model (see section 3 for what that permits).
b) Fork-based access: if your role does not include Write access to the
repository, you contribute by forking it into your own account and
opening Pull Requests from your fork. This is the expected model for
most Contributors in this setup, and is not a limitation to work
around — it is the intended mechanism that prevents non-approvers from
merging (see section 10 of the Approver document for why).

You will be notified by email or in-app GitHub notification when added to
the organization or a team. Accept the invitation from the link provided, or
from https://github.com/settings/organizations.

2.2 Verifying your access

- Visit the repository's GitHub page. If you can view it and see a "Fork"
  or "Clone" option, your access is active.
- If the repository is private and you cannot see it at all, your access
  has not yet been granted — contact your administrator.

2.3 Cloning the repository

If you have direct Write access to a personal branch area (uncommon in this
model, but possible depending on configuration):

    git clone https://github.com/<org-name>/<repo-name>.git

If you are contributing via a fork (the expected path for most users):

1. On the repository's GitHub page, click "Fork" (top right).
2. This creates a copy under your own GitHub account:
   https://github.com/<your-username>/<repo-name>
3. Clone your fork:

   git clone https://github.com/<your-username>/<repo-name>.git

2.4 HTTPS vs. SSH

Either works. HTTPS requires a Personal Access Token or GitHub's credential
manager/browser sign-in when prompted for a password (GitHub no longer
accepts your account password directly for git operations). SSH requires an
SSH key added to your GitHub account under Settings -> SSH and GPG keys. Use
whichever your organization's standard tooling already expects; if unsure,
HTTPS with the standard Git credential manager is the simpler default.

3. WHAT YOU CAN AND CANNOT DO

3.1 You CAN:

- Clone the repository (or your fork of it).
- Pull the latest changes from any branch you have read access to.
- Create new branches (in your fork, or directly in the repository if you
  have Write access there).
- Push commits to your own feature branches.
- Open Pull Requests targeting the protected branches (qa, uat, main).
- Update an open Pull Request by pushing additional commits.
- Respond to review comments and mark conversations as resolved.

3.2 You CANNOT:

- Push directly to a protected branch (qa, uat, main). This is blocked by
  a GitHub Ruleset requiring all changes to go through a Pull Request.
- Merge a Pull Request, including one you opened yourself, even after it
  has been approved. Only the Designated Approver (or another account
  explicitly granted that permission) can complete a merge.
- Approve your own Pull Request. GitHub blocks this outright for every
  account, regardless of role or team membership — there is no
  configuration that allows self-approval.
- Bypass required reviews or required status checks.
- Force-push to a protected branch (this is blocked separately from the
  Pull Request requirement).

4. STEP-BY-STEP WORKFLOW

The following assumes you are contributing via a fork, which is the default
expected path in this model. If you have direct Write access instead, skip
the fork-specific steps and work directly against the upstream repository.

Step 1 — Clone your fork

    git clone https://github.com/<your-username>/<repo-name>.git
    cd <repo-name>

Step 2 — Add the upstream repository as a remote (one-time setup)

    git remote add upstream https://github.com/<org-name>/<repo-name>.git

Step 3 — Checkout the correct base branch and update it

    git fetch upstream
    git checkout qa
    git pull upstream qa

(Replace "qa" with whichever branch your change is meant to reach first,
per your team's promotion process.)

Step 4 — Create a feature branch

    git checkout -b my-feature-branch

Step 5 — Make your changes

Edit the files as required for your task.

Step 6 — Commit your changes

    git add .
    git commit -m "Describe your change clearly"

Step 7 — Push your feature branch to your fork

    git push origin my-feature-branch

Step 8 — Create a Pull Request

1. Go to your fork's GitHub page. GitHub usually shows a "Compare & pull
   request" banner automatically after a push.
2. Click it, or go to the upstream repository and select
   "New pull request," then choose your fork/branch as the source and
   the correct branch (qa/uat/main) as the base.
3. Confirm the base branch is correct before submitting.

Step 9 — Add a clear description

Explain what the change does and why. Reference any related ticket or issue
if applicable.

Step 10 — Wait for review

The Pull Request will show a banner such as "Review required from Code
Owners" until the Designated Approver reviews it. No action is needed from
you at this point.

Step 11 — Address requested changes, if any

If the Designated Approver requests changes:

    # make the requested edits
    git add .
    git commit -m "Address review feedback"
    git push origin my-feature-branch

The Pull Request updates automatically; no need to open a new one.

Step 12 — Wait for required checks (if configured)

If automated checks (for example, a CI/CD pipeline) are configured to run
on Pull Requests, wait for them to complete and pass.

Step 13 — Verify approval status

Refresh the Pull Request page. Once approved and all required checks pass,
the page will indicate the Pull Request is ready to merge.

Step 14 — Hand off for merge

Even though the Pull Request is "ready," the merge button will not be
available to you. Notify the Designated Approver (or wait for them to
notice, depending on your team's process) that the change is ready to be
merged.

Step 15 — After merge

Once merged, update your local branches:

    git checkout qa
    git pull upstream qa

Delete your feature branch if no longer needed:

    git branch -d my-feature-branch
    git push origin --delete my-feature-branch

5. HANDLING MERGE CONFLICTS

If GitHub reports "This branch has conflicts that must be resolved":

    git fetch upstream
    git checkout my-feature-branch
    git merge upstream/qa
    # Git will mark the conflicting sections in the affected files.
    # Edit each file to resolve the conflict, then:
    git add <resolved-file>
    git commit
    git push origin my-feature-branch

The Pull Request will update automatically once the resolved commit is
pushed.

6. TROUBLESHOOTING (USER-FACING)

Problem: I cannot clone the repository.
Cause: your access has not been granted yet, or you are trying to clone
the upstream repository directly without Write access.
Resolution: confirm with your administrator that you have been added, or
fork the repository and clone your fork instead.

Problem: git push is rejected with "Changes must be made through a pull
request."
Cause: you attempted to push directly to a protected branch.
Resolution: push to a feature branch instead, and open a Pull Request.

Problem: I don't see a "Merge" button, or it is greyed out, even though my
Pull Request shows as approved.
Cause: this is expected. Only the Designated Approver (or another
explicitly authorized account) can complete a merge in this model.
Resolution: notify the Designated Approver that the Pull Request is ready.

Problem: I approved my own Pull Request but it still shows as unapproved.
Cause: GitHub does not allow self-approval, regardless of team membership
or configuration.
Resolution: request review from someone else with approver permissions.

Problem: My Pull Request still shows "Review required from Code Owners"
after the Designated Approver looked at it.
Cause: either the Approver only commented rather than submitting a formal
"Approve" review, or approved a stale version of the branch and new
commits were pushed afterward, dismissing that approval.
Resolution: ask the Approver to open the "Files changed" tab, click
"Review changes," select "Approve," and click "Submit review."

Problem: My Pull Request shows a required check has failed.
Cause: an automated check (for example, a CI/CD pipeline step) did not
pass.
Resolution: open the check's details, identify the failure, push a fix,
and wait for the check to re-run.

7. YOUR PART IN THE OVERALL MODEL (SUMMARY)

- You develop code and open Pull Requests.
- You cannot merge anything yourself, including your own approved
  changes.
- Only the Designated Approver can approve a Pull Request, and only the
  Designated Approver (or another explicitly authorized account) can
  complete the merge.
- Direct pushes to qa/uat/main are not possible for you; everything goes
  through review.
- If anything in this workflow behaves unexpectedly, refer to section 6
  above, or contact your administrator — do not attempt to work around a
  blocked action, as the restrictions are intentional.
