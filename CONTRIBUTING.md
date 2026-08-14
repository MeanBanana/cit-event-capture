# Contributing Guidelines

Welcome to the Argus Shield project. This document explains how team members should contribute to the GitHub repository — branching, committing, reviewing, synchronising, and merging. Following this workflow keeps the project organised and prevents conflicts.

For an overview of the project and folder structure, see [README.md](./README.md).

---

# Git Workflow Overview

```text
Create Branch
      |
      v
Make Changes
      |
      v
Commit Changes
      |
      v
Keep Branch Updated
      |
      v
Push Branch
      |
      v
Create Pull Request
      |
      v
Code Review
      |
      v
Merge Into Main
```

The `main` branch is the stable, tested version of the project. No one should push directly to `main` — all work happens on a separate branch.

---

# Choosing a Branch

Create a branch named after the area you're working on, using the relevant prefix from the table below (see README for the full purpose list):

* `android-development`
* `backend-development`
* `ai-development`
* `web-development`
* `database-development`
* `documentation`

You may also use more specific, descriptive branch names for individual tasks, for example:

```bash
git checkout -b feature/backend-login
git checkout -b bugfix/android-camera
git checkout -b web-dashboard
```

These are just examples. Ensure you are not working on the same branch as another team member, as this may cause merge conflicts.

Be descriptive with branch naming, and feel free to create your own branches as long as they clearly describe the work being done.

---

# Where Files Belong

GitHub does not decide where files are placed — the folder structure on your computer determines where a file appears in the repository.

For example, creating:

```text
backend/api/login.py
```

locally will result in that same path on GitHub.

Only add or modify files inside the folder related to your assigned task. If unsure where a file belongs, or if you need to modify another component's folder, communicate with the team first.

---

# Step-by-Step Process

## 1. Update Your Local `main` Branch

Before starting new work, make sure your local `main` branch contains the latest version from GitHub.

First switch to `main`:

```bash
git checkout main
```

Then pull the latest changes:

```bash
git pull origin main
```

This ensures that your new branch starts from the latest version of the project.

---

## 2. Check or Create Your Branch

Check your current branch:

```bash
git branch
```

The branch marked with `*` is your current branch.

If you need to create a new branch:

```bash
git checkout -b your-branch-name
```

For example:

```bash
git checkout -b feature/backend-login
```

If the branch already exists, switch to it:

```bash
git checkout your-branch-name
```

---

## 3. Make Your Changes

Create or edit files inside the correct folder for your task (see the README project structure).

Only modify files that are relevant to your assigned task.

If your work requires changes to another component or another team member's section, communicate with the team before making those changes.

---

## 4. Check Your Changes

Before committing, check which files have been modified:

```bash
git status
```

Confirm that the listed files match what you intended to modify.

Do not commit unrelated changes.

---

## 5. Add Your Changes

Add a specific file:

```bash
git add filename
```

Or add all relevant changes:

```bash
git add .
```

Only stage files related to your task.

---

## 6. Commit Your Changes

Commit your changes with a clear and descriptive message:

```bash
git commit -m "Description of change"
```

### Good commit messages

```text
Added user authentication API
Created Android camera activity
Updated database schema
Implemented image processing module
```

### Bad commit messages

```text
stuff
changes
update
fixed things
```

Commit messages should explain what was changed.

---

# Keeping Your Branch Up to Date

The `main` branch may change while you are working on your feature. Other team members may merge their work into `main` while your branch is still being developed.

You should regularly synchronize your feature branch with the latest `main` branch.

This is especially important **before creating a Pull Request**. Updating your branch early helps identify and resolve merge conflicts before your Pull Request is reviewed or merged.

---

## Updating Your Feature Branch

First, make sure your current work is committed:

```bash
git status
```

If you have uncommitted changes, commit them before updating your branch:

```bash
git add .
git commit -m "Description of current changes"
```

Then switch to `main`:

```bash
git checkout main
```

Pull the latest changes from GitHub:

```bash
git pull origin main
```

Now switch back to your feature branch:

```bash
git checkout your-branch-name
```

Merge the updated `main` branch into your feature branch:

```bash
git merge main
```

If there are no conflicts, Git will complete the merge automatically.

Test your project after the merge to make sure that the latest changes from `main` have not broken your work.

Finally, push your updated feature branch:

```bash
git push origin your-branch-name
```

Your feature branch is now synchronized with the latest version of `main`.

---

## Recommended Synchronization Workflow

When you want to update your branch, the process is:

```bash
git status
git add .
git commit -m "Save current work"

git checkout main
git pull origin main

git checkout your-branch-name
git merge main

# Test your project

git push origin your-branch-name
```

You do not need to run `git add .` and `git commit` if you have no uncommitted changes.

---

# Handling Merge Conflicts

A merge conflict occurs when Git finds changes on your branch and changes on `main` that affect the same part of a file, and Git cannot automatically determine which changes should be kept.

For example, after running:

```bash
git merge main
```

Git may report that a conflict has occurred.

Check the affected files:

```bash
git status
```

Git will identify the files that need to be resolved.

---

## Resolving a Merge Conflict

Open each conflicted file.

Git will add conflict markers similar to:

```text
<<<<<<< HEAD
Your changes
=======
Changes from main
>>>>>>> main
```

The sections mean:

```text
<<<<<<< HEAD
Your version of the code
=======
The version from main
>>>>>>> main
```

Review both versions and decide what the final code should contain.

You may:

* Keep your changes.
* Keep the changes from `main`.
* Combine both changes.
* Rewrite the affected section so that both changes work correctly.

After deciding what the final code should look like, remove the conflict markers:

```text
<<<<<<< HEAD
=======
>>>>>>> main
```

The file should contain only the final code.

---

## After Resolving Conflicts

Check that all conflicts have been resolved:

```bash
git status
```

Stage the resolved files:

```bash
git add .
```

Complete the merge:

```bash
git commit -m "Resolve merge conflicts with main"
```

Test the project thoroughly.

Once you are confident that everything works correctly, push your branch:

```bash
git push origin your-branch-name
```

---

# Important Rules When Resolving Conflicts

* Do not blindly choose one version of the code.
* Understand what both sides of the conflict are changing.
* Make sure the final code contains everything that is required.
* Test the affected functionality after resolving conflicts.
* If you are unsure how to resolve a conflict, communicate with the relevant team member before continuing.
* Never delete another person's work simply to make a conflict disappear.
* Do not force-push over another team member's branch.
* If the conflict involves major architectural or cross-component changes, discuss it with the team before resolving it.

---

# When Should You Synchronise?

You should synchronise your feature branch with `main`:

* Before starting a new piece of work.
* Regularly while working on a long-running feature.
* Before creating a Pull Request.
* When another team member has merged significant changes into `main`.
* Before continuing work after being away from the project for some time.

Do not wait until the end of a large feature to discover that your branch has conflicts with `main`.

Smaller, regular merges are generally easier to resolve than one large merge after several weeks of development.

---

# Push Your Branch

Once your changes have been committed and tested, push your branch to GitHub:

```bash
git push origin your-branch-name
```

For a new branch that has not previously been pushed, you can use:

```bash
git push -u origin your-branch-name
```

Do not push directly to `main`.

---

# Pull Request Process

Every change must go through a Pull Request before merging into `main`.

Before creating a Pull Request:

1. Make sure your branch contains your latest changes.
2. Synchronise your branch with the latest `main`.
3. Resolve any merge conflicts.
4. Test your project.
5. Push your updated branch to GitHub.
6. Create the Pull Request.

A Pull Request description should include:

* **Changes** — what was changed.
* **Testing** — how it was tested.
* **Known Issues** — anything outstanding.

Example:

```text
Changes:
- Added vehicle detection API
- Connected backend to database

Testing:
- Tested API requests using Postman

Known Issues:
- Processing speed requires improvement
```

Another team member must review and approve the Pull Request before it is merged into `main`.

---

# Code Review Checklist

When reviewing a Pull Request, check:

* Does the code work?
* Is the code understandable?
* Is it placed in the correct folder?
* Could it break another system component?
* Has it been tested?
* Has the branch been synchronised with the latest `main`?
* Are there any unresolved merge conflicts?
* Are any sensitive files or credentials included?
* Are the changes relevant to the Pull Request?
* Does the Pull Request description explain the changes and testing?

---

# Merging a Pull Request

Only merge a Pull Request after:

* The required code review has been completed.
* Another team member has approved the Pull Request.
* Any requested changes have been addressed.
* The project has been tested.
* Merge conflicts have been resolved.
* The Pull Request is ready to be merged into `main`.

Do not merge your own work without the required team approval.

Once merged, contributors should update their local `main` branch before starting new work:

```bash
git checkout main
git pull origin main
```

---

# Security Guidelines

Never commit:

* Passwords or credentials.
* API keys.
* Personal information.
* Sensitive datasets.
* Secrets hard-coded in source files.
* Temporary or generated build files.
* `node_modules/`
* `build/`
* `.gradle/`
* `venv/`

Use environment variables for private information, and ensure sensitive files are listed in `.gitignore`.

For example:

```text
.env
credentials.json
passwords.txt
database_passwords.txt
```

Before pushing your changes, check `git status` to make sure sensitive or generated files have not accidentally been staged.

---

# File Naming

Use clear, descriptive file names.

### Good

```text
UserAuthentication.java
vehicle_detection.py
database_schema.sql
```

### Bad

```text
test.py
newfile.java
thing2.py
```

File names should clearly describe their purpose.

---

# GitHub Issues

Use GitHub Issues to track tasks, bugs, features, and improvements.

Each issue should include:

* Description of the task.
* Assigned team member.
* Expected outcome.

Examples:

```text
Bug: Vehicle detection crashes when uploading video
Feature: Add investigator search function
Task: Create database relationship diagram
```

Keep issues updated as work progresses.

---

# General Rules

All contributors must:

* Work on their own branch.
* Never commit directly to `main`.
* Pull the latest `main` before starting new work.
* Regularly synchronise their feature branch with `main`.
* Place files in the correct project folder.
* Check changes using `git status` before committing.
* Write meaningful commit messages.
* Test their work before pushing.
* Resolve merge conflicts carefully.
* Communicate before modifying another person's section or making major changes.
* Create a Pull Request for changes that will be merged into `main`.
* Wait for Pull Request approval before merging.
* Never force-push over another team member's branch.
* Never commit passwords, API keys, credentials, personal information, or other sensitive data.

---

# Quick Reference

### Start new work

```bash
git checkout main
git pull origin main
git checkout -b your-branch-name
```

### Save your work

```bash
git status
git add .
git commit -m "Description of change"
```

### Update your branch with `main`

```bash
git checkout main
git pull origin main
git checkout your-branch-name
git merge main
```

### If there are conflicts

```bash
git status

# Resolve conflicts in the affected files

git add .
git commit -m "Resolve merge conflicts with main"
```

### Test and push

```bash
# Test your project

git push origin your-branch-name
```

### Create a Pull Request

```text
Feature branch
      |
      v
Synchronise with main
      |
      v
Resolve conflicts
      |
      v
Test
      |
      v
Push branch
      |
      v
Create Pull Request
      |
      v
Code Review
      |
      v
Approval
      |
      v
Merge into main
```

Following this workflow keeps everyone's work separate while ensuring that feature branches stay compatible with the latest version of the project.
