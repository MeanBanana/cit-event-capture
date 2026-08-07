# Contributing Guidelines

Welcome to the Argus Shield project. This document explains how team members should contribute to the GitHub repository — branching, committing, reviewing, and merging. Following this workflow keeps the project organised and prevents conflicts.

For an overview of the project and folder structure, see [README.md](./README.md).

---

# Git Workflow Overview

```
Create Branch
      |
      v
Make Changes
      |
      v
Commit Changes
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

Create a branch named after the area you're working on, using the relevant prefix from the table below (see README for the full purpose list): example `android-development`, `backend-development`, `ai-development`, `web-development`, `database-development`, `documentation`.

You may also use more specific, descriptive branch names for individual tasks, e.g.:

```bash
git checkout -b backend-login
git checkout -b android-camera
git checkout -b web-dashboard
```

These are just examples, ensure you are not working on the same branch as a team member, it may cause merge conflicts, be descriptive with branch naming, feel free to create your own branches

---

# Where Files Belong

GitHub does not decide where files are placed — the folder structure on your computer determines where a file appears in the repository.

Example: creating `backend/api/login.py` locally will result in that same path on GitHub.

Only add or modify files inside the folder related to your assigned task. If unsure where a file belongs, or if you need to touch another component's folder, communicate with the team first.

---

# Step-by-Step Process

## 1. Update Your Local Repo

```bash
git pull origin main
```

## 2. Check or Switch Branch

```bash
git branch
```

The branch marked with `*` is your current branch. Switch or create as needed:

```bash
git checkout -b your-branch-name
```

## 3. Make Your Changes

Create or edit files inside the correct folder for your task (see README project structure).

## 4. Check Your Changes

```bash
git status
```

Confirm the listed files match what you intended to modify.

## 5. Add Your Changes

Add a specific file:

```bash
git add filename
```

Or all changes:

```bash
git add .
```

Only stage files related to your task.

## 6. Commit Your Changes

```bash
git commit -m "Description of change"
```

**Good commit messages** (clear, specific):
```
Added user authentication API
Created Android camera activity
Updated database schema
Implemented image processing module
```

**Bad commit messages** (vague):
```
stuff
changes
update
fixed things
```

## 7. Push Your Branch

```bash
git push origin branch-name
```

---

# Pull Request Process

Every change must go through a Pull Request before merging into `main`.

A Pull Request description should include:

- **Changes** — what was changed
- **Testing** — how it was tested
- **Known Issues** — anything outstanding

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

Another team member must review and approve before it's merged.

---

# Code Review Checklist

When reviewing a Pull Request, check:

- Does the code work?
- Is the code understandable?
- Is it placed in the correct folder?
- Could it break another system component?
- Has it been tested?

---

# Security Guidelines

Never commit:

- Passwords or credentials
- API keys
- Personal information
- Sensitive datasets
- Secrets hard-coded in source files
- Temporary or generated build files (`node_modules/`, `build/`, `.gradle/`, `venv/`)

Use environment variables for private information, and ensure sensitive files are listed in `.gitignore`, e.g.:

```
.env
credentials.json
passwords.txt
database_passwords.txt
```

---

# File Naming

Use clear, descriptive file names.

**Good:**
```
UserAuthentication.java
vehicle_detection.py
database_schema.sql
```

**Bad:**
```
test.py
newfile.java
thing2.py
```

---

# GitHub Issues

Use GitHub Issues to track tasks, bugs, features, and improvements. Each issue should include:

- Description of the task
- Assigned team member
- Expected outcome

Examples:

```text
Bug: Vehicle detection crashes when uploading video
Feature: Add investigator search function
Task: Create database relationship diagram
```

---

# General Rules

All contributors must:

- Work on their own branch, never commit directly to `main`.
- Pull the latest `main` before starting new work.
- Place files in the correct project folder.
- Check changes (`git status`) before committing.
- Write meaningful commit messages.
- Test their work before pushing.
- Communicate before modifying another person's section or making major changes.
- Wait for PR approval before merging.
