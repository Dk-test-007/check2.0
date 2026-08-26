ACCESS ENABLEMENT DOCUMENT — DESIGNATED APPROVER
(Includes complete environment setup and administration reference)

Applies to: the Designated Approver of a private GitHub repository under a
GitHub Organization, who is also assumed to be the person setting up and
administering this environment unless a separate administrator role exists
in your organization. Where this document says "Administrator," it means
whoever performs GitHub Organization/repository configuration — in a small
team this is often the same person as the Designated Approver.

Example environment referenced throughout: Organization "Dk-test-007",
repository "check2.0", protected branches "qa", "uat", "main", approver team
"release-approvers." Replace these with your own names as needed — nothing
in this document depends on these specific names except where noted.

1. INTRODUCTION

1.1 Purpose

This document explains, in full, how to build a GitHub environment where:

- All authorized users can create branches and open Pull Requests.
- Users can contribute code through Pull Requests.
- Users cannot merge Pull Requests on their own.
- A single Designated Approver (or a small, named group acting as one) is
  responsible for approving Pull Requests.
- A Pull Request can be merged only after the Designated Approver has
  approved it.
- The Designated Approver is the only party authorized to perform the
  merge.
- Direct pushes to protected branches are not allowed for normal users.
- The setup works for a private repository inside a GitHub Organization.

It also explains the Designated Approver's day-to-day review and merge
responsibilities, and how to maintain the environment over time.

1.2 Why Pull Request approval is required

Protected branches represent shared, promoted, or production-facing code
states. Requiring review before anything reaches them prevents unreviewed
or unintended changes from landing, and creates an audit trail of who
approved what and when.

1.3 Contributor vs. Designated Approver

- A Contributor (User) can create branches, push changes, and open Pull
  Requests, but cannot merge, even an already-approved Pull Request.
- The Designated Approver reviews, approves or requests changes, and is
  the only party who can complete a merge.

1.4 Intended workflow

User creates branch -> User makes changes -> User pushes branch -> User
creates Pull Request -> Designated Approver reviews -> Designated
Approver approves -> Pull Request becomes mergeable -> Designated
Approver merges the Pull Request.

1.5 What happens in specific situations

- PR approved: merge becomes possible for the Designated Approver only.
- PR rejected / changes requested: the PR returns to pending status until
  the contributor pushes updates.
- PR updated after approval: with "dismiss stale reviews on push" enabled
  (recommended, see section 5), a new push clears the prior approval and
  requires re-review.
- PR has merge conflicts: GitHub blocks merging and instructs resolution
  via command line; see section 8.6.
- Required checks fail: merging is blocked until the checks pass again.
- Unauthorized user attempts to merge: the merge action is unavailable to
  them, regardless of the Pull Request's approval status, because they
  lack sufficient repository permission (see section 10).
- Unauthorized user attempts to push directly to a protected branch: the
  push is rejected with "Changes must be made through a pull request."

2. REQUIRED GITHUB ARCHITECTURE

The complete architecture consists of:

- A GitHub Organization (private repositories require an Organization,
  or a personal account with the appropriate plan; an Organization is
  recommended for team-based access control).
- A private repository within that Organization.
- Two GitHub Teams:
  - A Contributor/User team (or individual collaborators, or no
    explicit team at all if contribution happens purely via forks from
    outside the organization).
  - A Designated Approver team, e.g. "release-approvers." A team is
    used even for a single approver, because a team can be referenced
    by name in configuration and its membership can change without
    touching that configuration (see section 6).
- Repository access assignments for each team.
- A CODEOWNERS file naming the Designated Approver team as the owner of
  all files.
- One or more GitHub Rulesets on the protected branches, requiring a
  Pull Request, requiring Code Owner review, and restricting deletions
  and force pushes.
- An organization-wide Base Permission setting low enough that it does
  not silently grant Write access to everyone (see section 4.4 and
  section 10 — this is the single most commonly overlooked setting).
- Optionally, GitHub Environments and Actions workflows if CI/CD is part
  of the setup (see sections 12 and 13).

Recommended team structure and why:

- "release-approvers": holds the Designated Approver(s). Granted Write
  access to the repository. Referenced by CODEOWNERS and required by the
  Ruleset's Code Owner review requirement.
- Contributors: either added individually with Read access, or not added
  as organization members at all and left to contribute via forking a
  public-to-them or shared-visibility fork path. Do not grant Write
  access to this group — Write access is what actually allows completing
  a merge, and granting it defeats the entire model (see section 10).

Do not use individual usernames directly in CODEOWNERS instead of a team
unless there will only ever be exactly one approver and it will never
change. A team of one still behaves as "one approver" for all practical
purposes, but is far easier to maintain — replacing the approver later is a
team membership change, not a configuration file change (see section 6.5).

3. PREREQUISITES

3.1 GitHub Organization Owner must have/configure:

- Organization Owner role (to create teams, change organization-wide
  permission settings, and manage billing/plan if relevant).
- Decision on the organization's Base Permission level (must end up at
  "Read" or lower for this model to hold — see section 4.4).
- Decision on whether repository forking is allowed (required if
  Contributors will not be given Write access directly).

3.2 Repository Administrator must have/configure:

- Admin role on the specific repository (to create Rulesets, add
  CODEOWNERS, and manage repository-level collaborator/team access).
- The final repository name and default branch decided in advance.
- The list of protected branches decided in advance (this document uses
  qa, uat, main as the example).

3.3 Normal User needs:

- Organization membership or, if not an organization member, the ability
  to fork the repository (requires the repository to allow forking).
- Git installed locally, and either an SSH key or HTTPS
  credential/Personal Access Token configured for authentication.

3.4 Designated Approver needs:

- Membership in the approver team ("release-approvers").
- Write access to the repository (granted via that team, not
  individually — see section 4.4).
- The same Git/authentication setup as a normal user, plus familiarity
  with the review and merge steps in section 8.

3.5 GitHub plan / feature requirements

- GitHub Teams, CODEOWNERS, and Repository Rulesets (branch-level "Require
  a pull request before merging" plus "Require review from Code Owners")
  all work on private repositories on every GitHub plan, including Free.
  This is the mechanism this document relies on.
- GitHub Environments' own "Required reviewers" deployment protection
  rule is different and more limited: it is available on private
  repositories only on GitHub Team or GitHub Enterprise Cloud, not Free.
  Public repositories get this feature on every plan. If your CI/CD needs
  a deployment-level (not just merge-level) approval gate and your
  repository is private on a Free plan, that specific feature will not be
  available in Settings -> Environments — the workaround is to rely on the
  Pull Request-level approval documented here instead, since it produces
  an equivalent practical outcome (nothing reaches the branch that
  triggers deployment without approval).

3.6 Actions / token prerequisites (only if CI/CD is part of the environment)

- A GitHub Actions workflow file in the repository.
- Deployment credentials stored as Environment secrets, one per target
  environment.
- "Read and write permissions" enabled under Settings -> Actions ->
  General -> Workflow permissions, only if the workflow needs to push
  tags or commits back to the repository.
- See sections 12 and 13 for how this connects to the access model.

3.7 Salesforce CLI / CI/CD prerequisites (if applicable)

- Salesforce CLI (sf) available in the CI environment.
- One Salesforce org per target environment, each with a generated
  SFDX auth URL stored as that environment's secret.
- See section 13 for the full integration explanation.

4. ENVIRONMENT SETUP FROM SCRATCH

This section assumes nothing has been configured yet.

4.1 Create or verify the GitHub Organization

1. Go to https://github.com/settings/organizations.
2. If no organization exists yet, click "New organization" and follow the
   prompts (choose a plan; Free is sufficient for this model).
3. If an organization already exists, confirm you are listed as an Owner:
   https://github.com/orgs/<org-name>/people — your role is shown next to
   your name.
4. Verify admin access by opening
   https://github.com/organizations/<org-name>/settings/profile — if you
   can view this page without an error, you have sufficient access.

4.2 Create the private repository

1. From the organization page, click "New repository."
2. Owner: select the organization, not your personal account.
3. Repository name: choose a clear, final name — renaming later is
   possible but updates every clone URL.
4. Visibility: select "Private."
5. Initialize with a README if this is a brand-new project (recommended,
   so the repository has an initial commit and a default branch to work
   from). If migrating existing code, skip this and push it directly.
6. Default branch: GitHub creates this automatically (commonly "main").
   Confirm which branch is marked "Default" under Settings -> Branches
   after creation — this is the branch new clones check out by default
   and is typically your production-facing branch in this model.

4.3 Create GitHub Teams

1. Go to https://github.com/orgs/<org-name>/teams -> "New team."
2. Create the approver team:
   - Name: release-approvers (or your chosen name).
   - Description: optional but recommended, e.g. "Sole approvers for
     merges into protected branches."
   - Click "Create team."
3. On the team page -> "Members" -> "Add a member" -> add the
   Designated Approver(s).
4. If you are using a separate Contributor team (optional — many setups
   skip this and manage contributors individually or via forking
   instead): repeat the above with a different name, e.g. "contributors."
5. Verify membership: the team's "Members" tab should list exactly the
   people intended, no more, no fewer.

Why teams instead of individual configuration: a team can be referenced
once in CODEOWNERS and in repository access settings. Adding, removing,
or replacing a person only requires changing team membership — no
configuration file or Ruleset needs to change when the person does.

4.4 Configure Repository Access

1. Go to the repository -> Settings -> Collaborators and teams.
2. Add the "release-approvers" team with role: Write.
   Write is the minimum role that allows completing a merge and pushing
   to non-protected branches; it does not, by itself, allow bypassing the
   Ruleset requirements configured in section 5.
3. If using a Contributor team, add it with role: Read.
   Read allows cloning and viewing the repository, and opening Pull
   Requests from a fork, but does not allow pushing branches directly to
   this repository or completing a merge.
4. Do not add any individual or team with Write, Maintain, or Admin
   access other than the approver team, unless they are also meant to be
   able to complete merges.
5. Critical interaction with organization settings: go to
   https://github.com/organizations/<org-name>/settings/member_privileges
   and check "Base permissions." This value is the minimum access every
   organization member has to every repository in the organization, and
   it cannot be lowered per-repository — only added to. If Base
   permissions is set to "Write" or higher, every organization member has
   Write access to this repository regardless of what you configured in
   step 2-4, and the entire "users cannot merge" requirement will not
   hold. Set Base permissions to "Read" (or "No permission" for an even
   stricter default) before relying on this setup.
6. How repository roles interact with Rulesets: Rulesets add restrictions
   on top of whatever a role would otherwise allow (for example, blocking
   direct pushes even for a Write-role account, unless that account is on
   the Ruleset's bypass list). Rulesets do not grant permissions a role
   does not already have. A Read-role account cannot be made able to
   merge by a Ruleset setting; a Write-role account can be prevented from
   pushing directly by a Ruleset even though its role would otherwise
   allow it.

Verification: after this step, an account with only Read access should
be unable to push a branch directly to this repository (git push will be
rejected due to insufficient permission, separate from any Ruleset).

4.5 Configure the Default Branch and identify protected branches

1. Settings -> Branches shows the current default branch.
2. Decide the full set of protected branches for your promotion model.
   This document's example uses qa, uat, main (main being the default
   branch and the most production-facing).
3. Direct pushes should be restricted on every one of these branches, not
   only the default branch — configure the Ruleset's target list to
   include all of them (see section 5).
4. Verification of this step happens after the Ruleset is created (section
   5.9), since branch protection in this model comes entirely from the
   Ruleset, not from a separate branch setting.

5. RULESET CONFIGURATION

This is the core enforcement mechanism. Repository Rulesets are GitHub's
current branch-protection system (the successor to "classic" branch
protection rules) and are used here because they support a bypass list with
explicit, opt-in exceptions rather than an implicit administrator bypass.

5.1 Navigation

Repository -> Settings -> Rules -> Rulesets -> New ruleset -> New branch
ruleset.

5.2 Ruleset name

Choose a descriptive name, e.g. "require-release-approval." Purely
organizational; does not affect behavior.

5.3 Enforcement status

Set to "Active." ("Evaluate" only logs what would happen without
actually blocking anything — useful for testing changes, but must be
switched to "Active" before relying on it.)

5.4 Target branches

Under "Target branches," add each protected branch by name: qa, uat,
main. Patterns can also be used (for example, a wildcard covering a
naming convention), but explicit branch names are simplest to audit.

5.5 Required rules and what each does

- Require a pull request before merging.
  What it does: blocks any direct push to a target branch from anyone not
  on the bypass list; the only way to change the branch becomes a Pull
  Request.
  Mandatory for this model: yes.

  Required approvals: set to 1.
  What it does: at least one submitted "Approve" review is required
  before merging.
  Mandatory: yes (this is the base approval count; see also "Require
  review from Code Owners" below, which controls WHO that approval must
  come from).

  Require review from Code Owners: enable this.
  What it does: the required approval must come from an account or team
  listed in the CODEOWNERS file for the changed paths, not just any
  collaborator. This is what makes the approval requirement mean
  "approval from the Designated Approver specifically," rather than
  "approval from anyone."
  Mandatory: yes — this is the single setting that ties the approval
  requirement to the Designated Approver team specifically.

  Dismiss stale pull request approvals when new commits are pushed:
  recommended enabled.
  What it does: if new commits are pushed after an approval was given,
  that approval is cleared and a fresh review is required.
  Mandatory: optional, but strongly recommended — without it, a
  contributor could get an early approval and then push unrelated,
  unreviewed changes before merging.

- Restrict deletions.
  What it does: prevents the branch itself from being deleted by anyone
  not on the bypass list.
  Mandatory: recommended, not strictly required by the core approval
  model, but protects against accidental loss of a protected branch.

- Block force pushes.
  What it does: prevents history-rewriting pushes to the branch, even
  from accounts that would otherwise have permission.
  Mandatory: recommended for the same reason as above — protects branch
  integrity independent of the approval workflow.

- Require status checks to pass before merging (if CI/CD is configured).
  What it does: blocks merging until named checks (for example, a CI/CD
  workflow's job) report success.
  Mandatory: only if your environment includes automated checks that must
  gate merging; see section 12.

- Require conversation resolution before merging.
  What it does: blocks merging until every review comment thread is
  marked resolved.
  Mandatory: optional. Adds discipline but is not required for the core
  "only the Designated Approver can merge" requirement.

5.6 Bypass list

Leave this empty for the strictest interpretation of "nobody merges
without approval, not even administrators." Repository Rulesets, unlike
classic branch protection, do not implicitly exempt administrators — an
empty bypass list means every rule above applies to every account,
including Organization Owners, unless you deliberately add someone here.
If you add an entry (for example, your own account, for emergency use),
understand that this creates an exception to everything configured above
for that specific account or role. Do not add "Organization admin" or
"Repository admin" as a bypass role unless you specifically intend for
every admin to be able to skip review — this is a common accidental
misconfiguration if suggested defaults are accepted without reading them.

5.7 Preventing accidental bypass

- Periodically review the bypass list (Settings -> Rules -> Rulesets ->
  click the ruleset -> Bypass list) — nothing else in GitHub's interface
  surfaces this proactively.
- Do not rely on repository role alone to prevent merging; role changes
  (section 4.4) and Ruleset bypass list changes are independent settings
  that must each be checked.

5.8 Repeat for a stricter production-only rule (optional)

If a smaller or different approver group should govern one specific
branch (for example, main) more strictly than the others, create a
second ruleset targeting only that branch, with the same "Require a pull
request" and "Require review from Code Owners" settings. Be aware this
requires that branch to have different CODEOWNERS content than the
others (see section 6.4 for the consequence of doing this — it creates a
recurring, expected merge conflict on that one file during promotion
between branches, which is resolved with a specific procedure, not
avoided).

5.9 Verification

1. As an account not on the bypass list, attempt: git push origin main
   (or whichever protected branch). Expect rejection with: "Changes must
   be made through a pull request."
2. Open a test Pull Request from an account without approver-team
   membership. Confirm the Pull Request shows "Review required from Code
   Owners" and the merge option is unavailable.
3. Have a Designated Approver account submit an "Approve" review (see
   section 8.2). Confirm the Pull Request becomes eligible for merge.
4. Confirm, from the non-approver account, that merge is still
   unavailable to them even though the Pull Request is approved (this
   confirms section 4.4's role restriction is also in effect, not just
   the review requirement).

5. DESIGNATED APPROVER CONFIGURATION

6.1 What a Designated Approver is, in GitHub terms

GitHub does not have a feature literally named "Designated Approver." The
behavior is built from two mechanisms used together:

1. CODEOWNERS + "Require review from Code Owners" (section 5.5), which
   determines whose approval satisfies the review requirement.
2. Repository role / Base permissions (section 4.4), which determines who
   can click "Merge" once that requirement is satisfied.

Both are required. Configuring only the first stops merging before
approval, but allows any Write-role account to complete the merge once
approved. Configuring only the second does not, by itself, require any
particular person's review at all.

6.2 Can GitHub require approval from one specific named individual?

Yes, in two ways:

a) List the individual directly in CODEOWNERS: `* @username`.
This works, but if that person ever leaves or changes, every file
referencing CODEOWNERS-based ownership must be edited.
b) List a GitHub Team containing exactly that one person:
`* @org-name/release-approvers`.
Functionally identical day-to-day, but replacing the person later is a
team membership change, not a file change. This is the recommended
approach and the one used throughout this document.

Either way, GitHub enforces "this specific account (or a member of this
specific team) must approve" correctly and reliably — this part is fully
supported, not a workaround.

6.3 Can another user "satisfy" the approval requirement instead?

No, provided "Require review from Code Owners" (section 5.5) is enabled and
CODEOWNERS correctly names only the intended approver/team. An approval
from any other account does not count toward the Code Owner review
requirement, even if the base "Required approvals" count would otherwise be
satisfied by their review. If you observe another user's approval
apparently satisfying the requirement, this indicates a misconfiguration —
see section 15 (Troubleshooting).

6.4 CODEOWNERS and branch targeting

CODEOWNERS is read from the target branch of the Pull Request, not the
source branch. This means different branches can have different
CODEOWNERS content, and GitHub will apply whichever branch is being merged
into.

Consequence: if you intentionally give one branch (e.g. main) a different
CODEOWNERS file than others (e.g. qa/uat), a normal "merge the lower branch
forward" promotion will show a Git conflict on the CODEOWNERS file every
single time, because the two branches are permanently different on that
one file by design. This is expected, not a bug. Resolve it as follows,
without corrupting the source branch's own copy:

    git fetch origin
    git checkout -b promote-fix origin/uat
    git merge origin/main
    git checkout --theirs .github/CODEOWNERS
    git add .github/CODEOWNERS
    git commit
    git push origin promote-fix

Then open the promotion Pull Request from "promote-fix" into "main" instead
of directly from "uat," so that "uat" itself never has its own CODEOWNERS
overwritten. If this recurring step is undesirable, use identical
CODEOWNERS content on every branch instead — simpler to maintain, at the
cost of not having a separate, stricter approver group for any one branch.

6.5 Replacing the Designated Approver

1. Add the new person to the approver team (section 4.3).
2. Remove the previous person from the team, if they should no longer
   approve.
3. No change to CODEOWNERS, Rulesets, or repository access settings is
   needed, provided a Team (not an individual username) was used in
   CODEOWNERS as recommended in section 6.2.
4. Confirm the new person has completed the account-level prerequisites
   in section 3.4.

6.6 If the Designated Approver is unavailable

- No Pull Request can be approved or merged until either the approver
  becomes available, a second person is temporarily added to the
  approver team, or an account on the Ruleset's bypass list intervenes
  (only if a bypass list entry exists — by default in this document's
  recommended configuration, it does not).
- Plan for this operationally: most real deployments of this model keep
  at least two people in the approver team, even if only one is meant to
  approve routine changes, specifically to avoid a single point of
  failure. This is a process decision, not a GitHub limitation.

6.7 A note on self-approval

GitHub blocks a Pull Request's author from approving their own Pull
Request, in every configuration, with no override. If the Designated
Approver is also the person making a change, a second approver-capable
account is required for that specific Pull Request. This is a genuine
GitHub-wide limitation, not specific to this setup, and there is no
supported way to disable it.

7. ACCESS ENABLEMENT DOCUMENT — REPOSITORY USER

See the separate document: "Access Enablement Document — Repository User."
It is intended to be handed to Contributors directly and does not require
any of the setup knowledge in sections 1-6 above.

8. YOUR DAY-TO-DAY USAGE AS DESIGNATED APPROVER

8.1 How you receive access

You are added to the approver team (section 4.3) by the Administrator. You
will receive a GitHub notification. Verify by confirming you can see
"Write" access indicators on the repository (for example, the ability to
see a "Settings" tab if also granted Admin, or simply the presence of an
active "Merge" button on an approved Pull Request you did not author).

8.2 Reviewing a Pull Request

1. Open the Pull Request.
2. Click the "Files changed" tab.
3. Review the diff line by line.
4. Review the "Commits" tab if you want to see the change broken out by
   individual commit rather than as a combined diff.
5. Review the "Checks" section (if automated checks are configured) to
   confirm they have passed.
6. To leave an inline comment on a specific line, click the "+" icon that
   appears when hovering over that line in "Files changed."
7. Top-right of "Files changed," click "Review changes."
8. Choose one:
   - "Comment": leaves feedback without approving or blocking.
   - "Approve": submits a formal approval, satisfying the Code Owner
     review requirement.
   - "Request changes": blocks merging until you (or another approver)
     later approve a subsequent revision.
9. Click "Submit review."

8.3 Merging after approval

1. Once your approval is submitted and any required checks pass, the
   "Merge pull request" button becomes active on the Pull Request page.
2. Choose a merge method if more than one is enabled (merge commit,
   squash, or rebase) — consistent with your team's convention.
3. Click "Merge pull request," then confirm.

8.4 Handling an invalid Pull Request

If a Pull Request should not be merged at all (wrong target branch, wrong
approach, superseded by other work), use "Close pull request" rather than
leaving it open indefinitely. Closing does not delete the branch or commits
unless you separately choose to delete the branch.

8.5 Handling failed checks

If a required status check fails, the merge option remains unavailable
regardless of your approval. Wait for the contributor to push a fix and for
the check to re-run, or investigate the check's log yourself if you have
access to do so.

8.6 Handling merge conflicts

If the Pull Request shows a conflict, GitHub will not allow a web-based
merge. Direct the contributor to resolve it (see the User document, section
5), or resolve it yourself via command line using the same procedure.

8.7 Revoking or replacing an approval

If you approved a Pull Request and then realize it needs further changes:
submit a new review with "Request changes." This does not retract your
prior "Approve" event from the history, but it does block merging again
until you (or another approver) submit a new "Approve" review. If "Dismiss
stale reviews on push" is enabled (section 5.5), any new commit pushed by
the contributor will do this automatically.

8.8 Verifying a Pull Request is genuinely ready to merge

Before merging, confirm on the Pull Request page:

- The review section shows an "Approved" state specifically from the
  required Code Owner (your team), not merely "no pending reviewers."
- Any required checks show green/passing, not pending or failed.
- There is no "This branch has conflicts" banner.
- You are not the author of the Pull Request (if you are, merging is
  still possible once someone else approves it, but you cannot have
  supplied that approval yourself).

9. PULL REQUEST LIFECYCLE

1. Branch creation — contributor creates a feature branch.
1. Code development — changes are made and committed locally.
1. Push — the branch is pushed to the contributor's fork or, if they have
   Write access, directly to the repository.
1. Pull Request creation — opened against a protected branch.
1. Reviewer assignment — GitHub automatically requests review from the
   CODEOWNERS-designated team based on the target branch.
1. Automated checks — any configured CI/CD workflow runs against the
   proposed change.
1. Designated Approver review — as in section 8.2.
1. Approval — a formal "Approve" review is submitted.
1. Requested changes (alternative path) — the contributor is asked to
   revise; loops back to step 3.
1. Developer updates — additional commits pushed in response.
1. Re-review — required again if approvals were dismissed on push.
1. Merge eligibility — all required conditions (approval, checks,
   conflict-free) are satisfied.
1. Merge — the Designated Approver completes the merge.
1. Post-merge deployment (if CI/CD is configured) — a workflow triggers
   automatically on the push that the merge produces; see section 12.

1. MERGE CONTROL

10.1 Who can click "Merge"

Only accounts with sufficient repository role (Write or higher — section
4.4) whose review satisfies the Code Owner requirement chain can complete a
merge once a Pull Request is approved. In this model, that is the
Designated Approver team.

10.2 Who cannot

Any account with Read-only access (the expected role for Contributors in
this model) will not see an active "Merge" control, regardless of the Pull
Request's approval status. If they attempt to merge via the API or another
tool without sufficient permission, the action is rejected by GitHub
directly — there is no path that succeeds.

10.3 Approve vs. Merge — these are separate permissions

Submitting an "Approve" review requires only that the reviewer be
recognized as a Code Owner for the relevant paths (section 5.5) and is not
by itself a repository permission — even a Read-role Code Owner can submit
an approval if listed in CODEOWNERS. Completing the actual merge requires
Write-level repository access (or higher). In this model both happen to be
held by the same team, but they are enforced by different mechanisms:
CODEOWNERS/Ruleset for approval, repository role for merge capability. Do
not assume granting "Write" automatically makes someone a required
approver, or that CODEOWNERS membership automatically grants merge rights
— configure both explicitly as described in sections 4.4 and 5.5.

10.4 Administrator/Owner bypass

With an empty bypass list (section 5.6), Organization Owners and Repository
Admins are subject to the same restrictions as everyone else under Repository
Rulesets — this is a deliberate difference from GitHub's older "classic"
branch protection, which defaulted to exempting administrators unless told
otherwise. Do not assume an admin can always override; check the specific
Ruleset's bypass list if unexpected admin access to merge is observed
(section 15 covers this as a troubleshooting case).

10.5 If the Designated Approver approves but someone else tries to merge

If the repository role setup in section 4.4 is correct, this attempt fails
regardless of the approval status — a Read-role account cannot merge, full
stop. If it succeeds, this indicates that account has Write access it
should not have (commonly caused by the organization Base Permission
override described in section 4.4, step 5) — this is the most likely and
most important thing to check if this happens.

11. DIRECT PUSH PROTECTION

Configured via the Ruleset's "Require a pull request before merging" rule
(section 5.5), applied to every protected branch (section 5.4), with an
empty bypass list (section 5.6).

Expected error on a direct push attempt:

    remote: error: GH013: Repository rule violations found for refs/heads/main.
    remote: - Changes must be made through a pull request.
    ! [remote rejected] main -> main (push declined due to repository rule violations)

Verification: attempt `git push origin <protected-branch>` from any account
not on the bypass list and confirm the above (or equivalent) rejection.

Authorized users still make changes normally through the Pull Request flow
described in section 4 of the User document — this restriction only
affects direct pushes, not the ability to contribute.

12. REQUIRED CHECKS AND CI/CD INTEGRATION

If GitHub Actions is part of this environment:

- Workflows can be configured to run on Pull Request events (validating
  a proposed change before merge) and/or on push events to protected
  branches (deploying after merge).
- To make a check block merging, add it to the Ruleset's "Require status
  checks to pass before merging" rule (section 5.5), selecting the exact
  job name as it appears in Actions.
- A failing required check blocks the merge button regardless of
  approval status.
- A passing required check removes that specific blocker; merging is
  still also gated by the approval requirements in sections 5 and 6.
- Salesforce deployment validation (dry-run, Apex test execution) can be
  wired in as such a check — see section 13 for how this project's
  existing pipeline does it.
- A Dev -> QA -> UAT -> Production promotion model maps naturally onto
  this branch structure: each protected branch corresponds to one
  environment, and a merge into that branch (only possible after
  Designated Approver approval) is what triggers that environment's
  deployment.

13. SALESFORCE CI/CD INTEGRATION

This section describes how this access model integrates with a Salesforce
release pipeline, consistent with this project's existing architecture.

- Git branches (qa, uat, main) each map to one Salesforce org alias
  (qa, uat, prod).
- Each branch has a corresponding GitHub Environment holding that org's
  deployment credential (an SFDX auth URL) as an Environment secret.
- A GitHub Actions workflow triggers on push to each protected branch —
  which, in this model, only happens as the result of an
  approved-and-merged Pull Request, never a direct push.
- The workflow authenticates to Salesforce using the Environment secret,
  computes a delta of changed metadata since that org's last successful
  deploy, validates it with a dry run (including Apex test execution),
  and then performs the actual deployment.
- Salesforce CLI (sf) is used for authentication, delta generation, and
  deployment; Apex testing is enforced by Salesforce itself as part of
  the dry-run/deploy step, independent of GitHub.
- Production approval: this can be layered two ways — (a) the Pull
  Request approval documented in this guide, which gates whether the
  merge to the production branch happens at all, and/or (b) a GitHub
  Environment "Required reviewers" deployment gate on the production
  Environment specifically, if your repository/plan supports it (see the
  limitation noted in section 3.5). Both can be used together for
  defense in depth, or the Pull Request approval alone can serve as the
  single gate if Environment-level approval is unavailable.

The relationship in one sentence: GitHub (Rulesets, CODEOWNERS, repository
roles) controls who can contribute and merge; GitHub Actions controls what
happens automatically after an approved merge lands.

14. SETUP VERIFICATION AND TESTING

Positive tests

Test: User can clone the repository (or fork).
Steps: as a Contributor account, fork the repository and clone the
fork.
Expected result: clone succeeds.
Actual result: ______
Pass/Fail: ______

Test: User can create a branch and push it.
Steps: create a feature branch in the fork, commit a trivial change,
push it.
Expected result: push succeeds to the fork.
Actual result: ______
Pass/Fail: ______

Test: User can create a Pull Request.
Steps: open a Pull Request from the fork's branch into a protected
branch.
Expected result: Pull Request opens, shows "Review required from Code
Owners."
Actual result: ______
Pass/Fail: ______

Test: Designated Approver can review and approve.
Steps: as the approver account, open the Pull Request, submit an
"Approve" review.
Expected result: review recorded as "Approved," the pending Code Owner
review requirement clears.
Actual result: ______
Pass/Fail: ______

Test: Designated Approver can merge after approval.
Steps: click "Merge pull request" as the approver account.
Expected result: merge completes successfully.
Actual result: ______
Pass/Fail: ______

Test: CI/CD pipeline starts after merge (if configured).
Steps: observe the Actions tab immediately after the merge.
Expected result: a workflow run appears, targeting the correct
environment.
Actual result: ______
Pass/Fail: ______

Negative tests

Test: User cannot push directly to a protected branch.
Steps: as a Contributor account (or any account not on the bypass
list), attempt `git push origin <protected-branch>` directly.
Expected result: rejected with "Changes must be made through a pull
request."
Actual result: ______
Pass/Fail: ______

Test: User cannot merge a Pull Request, even an approved one.
Steps: as a Contributor account, open the approved Pull Request from
test 4 above (or a similar one) and attempt to merge.
Expected result: no active merge control is available to this account.
Actual result: ______
Pass/Fail: ______

Test: A user outside the approver team cannot satisfy the Code Owner
review requirement.
Steps: have a non-approver account submit an "Approve" review on a
Pull Request.
Expected result: the review is recorded, but the "Review required from
Code Owners" requirement remains unmet.
Actual result: ______
Pass/Fail: ______

Test: An unapproved Pull Request cannot be merged.
Steps: open a fresh Pull Request and attempt to merge it before any
approval is submitted.
Expected result: merge is blocked, showing the pending review
requirement.
Actual result: ______
Pass/Fail: ______

Test: Force pushes to a protected branch are blocked.
Steps: attempt `git push --force origin <protected-branch>`.
Expected result: rejected by the Ruleset's "Block force pushes" rule.
Actual result: ______
Pass/Fail: ______

Test: Required status checks block merging when failing (if configured).
Steps: open a Pull Request that intentionally fails a required check.
Expected result: merge is blocked until the check passes.
Actual result: ______
Pass/Fail: ______

15. TROUBLESHOOTING

Problem: User cannot clone the repository.
Cause: access not yet granted, or attempting to clone the upstream
repository directly without sufficient role.
Verification: confirm organization/team membership under
https://github.com/orgs/<org-name>/people.
Resolution: grant access, or direct the user to fork instead.

Problem: User cannot push a branch anywhere at all, including their own
fork.
Cause: authentication not configured (no SSH key or valid credential).
Verification: run `git push` and read the exact authentication error.
Resolution: configure SSH key or HTTPS credential per section 2.4 of the
User document.

Problem: User cannot create a Pull Request.
Cause: usually a UI/branch selection mistake, not a permissions issue —
opening a Pull Request does not itself require Write access on the base
repository when contributing via a fork.
Verification: confirm the correct base and head branches are selected on
the "New pull request" page.
Resolution: re-select branches; if still failing, confirm forking is
enabled (section 3.1) and the fork is up to date.

Problem: User can merge when they should not be able to.
Cause: almost always the organization Base Permission setting (section
4.4, step 5) granting Write to everyone, overriding intended per-team
access.
Verification: check
https://github.com/organizations/<org-name>/settings/member_privileges.
Resolution: lower Base permissions to Read; separately verify no
individual/team was directly granted Write on the repository outside the
approver team.

Problem: Approval requirement is not appearing on Pull Requests at all.
Cause: the Ruleset is not "Active" (may be left on "Evaluate"), or its
target branch list does not include the branch being merged into, or
CODEOWNERS is missing/misplaced.
Verification: check the Ruleset's enforcement status and target branches
(Settings -> Rules -> Rulesets); confirm CODEOWNERS exists at
`.github/CODEOWNERS` on the target branch specifically.
Resolution: set enforcement to Active; correct the target branch list;
add/move CODEOWNERS to the correct branch.

Problem: The wrong user (or any user) can satisfy the approval requirement.
Cause: "Require review from Code Owners" is not enabled on the Ruleset
(only a generic "Required approvals" count is set), or CODEOWNERS
contains a typo in the team/user reference.
Verification: re-check the Ruleset's pull_request rule parameters; check
CODEOWNERS spelling character by character against the team's actual
slug (Settings -> Teams -> team name, as shown in its URL).
Resolution: enable "Require review from Code Owners"; correct the typo.
Note: GitHub does not raise any error for a misspelled team reference in
CODEOWNERS — it silently matches nothing, which looks identical to "no
requirement configured" from the outside. Always verify by checking that
a review is actually requested from the intended team when a Pull
Request is opened, not just by reading the file.

Problem: Designated Approver cannot approve.
Cause: most commonly, they are the author of the Pull Request (GitHub
blocks self-approval unconditionally), or they are not actually a member
of the team named in CODEOWNERS, or that team lacks repository access.
Verification: confirm the PR author; confirm team membership; confirm the
team has at least Write (or Read, for approval purposes specifically —
see section 10.3) access to the repository.
Resolution: use a second approver account for self-authored changes; fix
team membership or repository access as needed.

Problem: Pull Request remains blocked after an apparent approval.
Cause: the approval may have been a "Comment," not a formally submitted
"Approve" review; or new commits were pushed afterward and dismissed the
approval (if that setting is enabled).
Verification: check the "Reviewers" panel on the Pull Request for an
explicit "Approved" status with a green check, not just a comment.
Resolution: submit a proper "Approve" review via "Review changes."

Problem: A required check is failing and blocking merge.
Cause: an underlying test, lint, or deployment validation step failed.
Verification: open the check's log directly from the Pull Request's
"Checks" section.
Resolution: fix the underlying issue and push again; the check re-runs
automatically.

Problem: Ruleset does not appear to be applying at all.
Cause: enforcement status set to "Evaluate" instead of "Active," or the
target branch pattern does not match the actual branch name.
Verification: Settings -> Rules -> Rulesets -> open the ruleset and check
both fields directly.
Resolution: correct enforcement status and/or target pattern.

Problem: Ruleset is applying in unexpected ways (e.g., blocking something
that should be allowed).
Cause: multiple Rulesets targeting the same branch combine their rules —
if two ruleset scapply to the same branch with different settings (for
example, one dismissing stale reviews and another not), the stricter
combined behavior applies.
Verification: list every ruleset whose target branches include the
affected branch, and review each one's rules together.
Resolution: remove the branch from whichever ruleset should not apply to
it, or align the conflicting settings.

Problem: User can still push directly to a protected branch.
Cause: either the Ruleset's target branch list does not actually include
that branch, or that user's account is present on the bypass list.
Verification: check both fields on the relevant Ruleset directly.
Resolution: correct the target list; remove the account from the bypass
list if it should not be there.

Problem: Administrator can bypass rules unexpectedly.
Cause: the Ruleset's bypass list includes an "Organization admin" or
"Repository admin" role entry, which was likely added by accepting a
suggested default without reviewing it.
Verification: open the Ruleset's Bypass list section directly.
Resolution: remove the role-based bypass entry if unintended.

Problem: Team permissions are not working as expected.
Cause: the team was created but never granted repository access (team
creation and repository access are two separate steps — section 4.3 vs.
4.4), or the team's repository role is lower than assumed.
Verification: Team page -> Repositories -> confirm the repository is
listed with the expected role.
Resolution: add or correct the repository access grant on the team.

Problem: CODEOWNERS is not triggering a review request at all.
Cause: the file is not at `.github/CODEOWNERS` (or one of the other two
supported locations: repository root, or `docs/CODEOWNERS`), or it exists
on the wrong branch (remember: read from the Pull Request's target
branch, section 6.4), or the referenced team/user has no repository
access.
Verification: confirm the file's exact path and branch; confirm the
referenced team has repository access.
Resolution: correct the file location/branch, or grant the team access.

Problem: GitHub Actions is not starting after merge.
Cause: the workflow's trigger configuration does not include the branch
that was just merged into, or Actions is disabled for the repository
(Settings -> Actions -> General).
Verification: check the workflow file's `on: push: branches:` list; check
the Actions enablement setting.
Resolution: add the branch to the trigger list, or enable Actions.

Problem: Deployment fails after merge.
Cause: this is a CI/CD/Salesforce-specific issue, separate from the
access model documented here. Common causes include an invalid or
expired deployment credential, insufficient Apex test coverage, or a
missing dependency in the deployed metadata.
Verification: review the failing job's log in the Actions run directly —
Salesforce deploy failures return a specific, readable error describing
the exact component or test that failed.
Resolution: address the specific reported cause; this is unrelated to
who approved or merged the Pull Request.

16. ADMINISTRATION AND MAINTENANCE

- Adding a user: add them to the organization and/or the appropriate team
  (section 4.3); do not grant Write access unless they are also becoming
  an approver.
- Removing a user: remove them from the organization and/or team; if they
  had a fork, it remains under their account but loses any special access
  to the upstream repository.
- Changing a user's role: adjust their team membership or, if
  individually added, their direct collaborator role under Settings ->
  Collaborators and teams.
- Adding/removing the Designated Approver: see section 6.5.
- Changing teams: create, rename, or delete teams under
  https://github.com/orgs/<org-name>/teams; renaming a team changes its
  slug, which requires updating any CODEOWNERS reference to match.
- Updating Rulesets: Settings -> Rules -> Rulesets -> select the ruleset
  to edit; changes take effect immediately for enforcement status
  "Active."
- Changing protected branches: add or remove branches from the Ruleset's
  target list (section 5.4); does not require recreating the ruleset.
- Updating required reviewers: edit CODEOWNERS content and/or team
  membership, per section 6.
- Updating required checks: edit the Ruleset's "Require status checks to
  pass" rule to add/remove specific check names.
- Updating GitHub Actions: edit the workflow file directly; changes apply
  to the next run after the file is merged into the branch being acted
  on.
- Rotating credentials: regenerate the relevant Salesforce auth URL
  (`sf org login web` then `sf org display --verbose --json`) and update
  the corresponding Environment secret; no code change required.
- Auditing permissions: periodically review Settings -> Collaborators and
  teams, each team's Repositories tab, and each Ruleset's target/rules/
  bypass configuration together — these are independent settings that
  combine to produce the effective access model, and none of them alone
  tells the full story.
- Reviewing bypass permissions: see section 5.7.
- Handling approver absence: see section 6.6.
- Offboarding a user: remove organization/team membership; if they had
  direct collaborator access, remove it explicitly, since removing team
  membership alone does not affect separately-granted individual access.

17. SECURITY AND GOVERNANCE

- Least privilege: Contributors receive Read access by default (section
  4.4); Write access is reserved for the approver team specifically.
- Separation of duties: the ability to author a change (any Contributor)
  is kept separate from the ability to approve it (Designated Approver
  only) and, further, self-approval is blocked unconditionally by GitHub.
- Protected branches: every promotion-relevant branch is covered by a
  Ruleset requiring review (section 5.4).
- Pull Request review: enforced via CODEOWNERS-gated required approval,
  not optional or convention-based.
- No direct production branch access: direct pushes to any protected
  branch are blocked outright (section 11).
- Audit trail: every merge has an associated Pull Request recording the
  author, the approver, the review comments, and the timestamp — this is
  a byproduct of the required-PR model, not a separate feature to
  configure.
- GitHub Actions security: workflows should never echo deployment
  secrets to logs; credentials should be piped via stdin or referenced
  only through `secrets.<NAME>`, never hardcoded.
- Secret management: store all deployment credentials as Environment
  secrets scoped to the relevant environment only, not as repository-wide
  secrets accessible to every workflow run regardless of target.
- Team-based access: preferred over individual grants throughout this
  document specifically because it decouples "who has access" from
  "what the access grants," easing personnel changes.
- Bypass control: keep the Ruleset bypass list empty unless a specific,
  documented exception is required (section 5.6/5.7).
- Administrator access: Organization Owner and Repository Admin roles
  should be held by as few accounts as practically possible, since these
  roles can change the Ruleset and permission configuration itself,
  effectively controlling the controls.

18. COMPLETE SETUP CHECKLIST

[ ] Organization created or verified; Owner access confirmed.
[ ] Private repository created under the organization.
[ ] Default branch identified and confirmed.
[ ] Approver team created (e.g. release-approvers); members added.
[ ] (Optional) Contributor team created; members added, or forking
confirmed enabled instead.
[ ] Approver team granted Write access to the repository.
[ ] Contributor team (if used) granted Read access only.
[ ] Organization Base permissions set to Read or lower.
[ ] No individual/team other than the approver team holds Write or
higher on the repository.
[ ] CODEOWNERS file added at `.github/CODEOWNERS` on every protected
branch, correctly referencing the approver team (spelling verified
against the team's actual slug).
[ ] Branch ruleset created, enforcement set to Active.
[ ] Ruleset target branches include every protected branch.
[ ] Ruleset requires a Pull Request before merging, with required
approvals set to at least 1.
[ ] Ruleset requires review from Code Owners.
[ ] Ruleset restricts deletions and blocks force pushes.
[ ] Ruleset bypass list reviewed and confirmed empty (or intentionally
populated with documented exceptions only).
[ ] Required status checks configured on the Ruleset, if CI/CD is part
of the environment.
[ ] GitHub Actions workflow file present and triggering on the correct
branches, if applicable.
[ ] GitHub Environments created per target environment, with deployment
secrets configured, if applicable.
[ ] Salesforce org connections established and auth URLs generated, if
applicable.
[ ] Repository forking confirmed enabled, if Contributors rely on it.
[ ] Direct-push verification performed (section 5.9 / section 11) and
confirmed blocked.
[ ] Approval verification performed (section 14, positive tests 3-4) and
confirmed working.
[ ] Merge verification performed (section 14, positive test 5, negative
test on non-approver merge attempt) and confirmed correct.
[ ] CI/CD verification performed (section 14, positive test 6), if
applicable.
[ ] Full end-to-end test completed: a real Contributor account taken
through fork -> branch -> PR -> approval -> merge -> (deployment, if
applicable), successfully.

19. FINAL OPERATING MODEL

- Who can develop: any authorized Contributor, via a feature branch and
  a Pull Request.
- Who can create Pull Requests: any authorized Contributor.
- Who can approve: only members of the Designated Approver team, as
  enforced by CODEOWNERS plus the Ruleset's "Require review from Code
  Owners" setting.
- Who can merge: only accounts with sufficient repository role (in this
  model, the same Designated Approver team, granted Write access), as
  enforced independently by repository permissions.
- Which branches are protected: every branch listed in the Ruleset's
  target branches (qa, uat, main in this document's example).
- What happens after approval: the Pull Request becomes eligible for
  merge, but only an account with sufficient role can actually complete
  it.
- What happens after merge: if CI/CD is configured, a workflow triggers
  automatically against the branch that was just updated, typically
  deploying to the corresponding environment.
- How CI/CD is triggered: by the push event that a completed merge
  produces — never by a direct push, since direct pushes to protected
  branches are not possible in this model.
- How unauthorized actions are prevented: direct pushes are blocked by
  the Ruleset; unauthorized merges are blocked by repository role;
  unauthorized approvals are blocked by the Code Owner requirement;
  self-approval is blocked by GitHub unconditionally.
- How administrators maintain the system: by managing team membership
  (for personnel changes), Ruleset configuration (for policy changes),
  and CODEOWNERS content (for changing who is required to review),
  treating these as three related but independently auditable settings.
