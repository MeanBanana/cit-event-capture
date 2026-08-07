# Contributing Guidelines

Welcome to the Argus project.

This document explains how team members should contribute to the GitHub repository. The goal is to keep the project organised, prevent conflicts, and ensure everyone follows the same development process.

---

# Project Structure

The Argus project contains multiple components. Each component has its own folder where related files should be stored.

```text
Argus/
│
├── android-app/     # Android Studio application (Java)
├── backend/         # Python backend/API/server
├── web-app/         # Website frontend (HTML, CSS, JavaScript, PHP)
├── database/        # Database scripts and documentation
├── ai/              # Computer vision and AI components
├── docs/            # Project documentation
└── testing/         # Testing files and reports
```

Team members should only add or modify files inside the folder related to their assigned task.

If you are unsure where a file belongs, communicate with the team before adding it.

---

# Branch Rules

The `main` branch is the stable version of the project.

Team members must not directly commit or push changes to `main`.

Each member should create their own branch before starting work.

Create a branch:

```bash
git checkout -b branch-name
```

Examples:

```bash
git checkout -b backend-login
git checkout -b android-camera
git checkout -b web-dashboard
git checkout -b database-setup
```

Branch names should describe the work being completed.

---

# How Files Are Added to GitHub

GitHub does not decide where files should be placed.

The location of a file is determined by where the file is created or edited on your computer.

For example, if you create:

```text
backend/api/login.py
```

Git records the location of the file.

After pushing to GitHub, the file will appear as:

```text
Repository
└── backend
    └── api
        └── login.py
```

The folder structure on your computer determines where the file appears on GitHub.

---

# Adding and Uploading Changes

Follow this process when adding new work to the repository.

## 1. Check Your Branch

Before making changes, confirm that you are working on the correct branch.

```bash
git branch
```

Example:

```text
* backend-login
  main
```

The branch with the `*` is your current branch.

---

## 2. Make Your Changes

Create or edit files inside the correct folder.

Examples:

Backend:

```text
backend/routes/login.py
```

Android:

```text
android/app/src/MainActivity.java
```

Web:

```text
web/dashboard/index.php
```

Database:

```text
database/schema.sql
```

AI:

```text
ai/detection.py
```

---

## 3. Check Your Changes

Before committing, check which files have been changed.

```bash
git status
```

Make sure the listed files are the files you intended to modify.

---

## 4. Add Your Changes

To add one specific file:

```bash
git add filename
```

Example:

```bash
git add backend/routes/login.py
```

To add all changes:

```bash
git add .
```

Only add files related to your task.

---

## 5. Commit Your Changes

Create a commit with a clear message describing what was changed.

Format:

```bash
git commit -m "Description of change"
```

Examples:

Good:

```bash
git commit -m "Added user authentication API"
```

```bash
git commit -m "Created Android camera activity"
```

```bash
git commit -m "Updated database structure"
```

Bad:

```bash
git commit -m "Changes"
```

```bash
git commit -m "Update"
```

```bash
git commit -m "Fixed stuff"
```

Commit messages should explain the purpose of the change.

---

## 6. Push Your Changes

Upload your branch to GitHub.

```bash
git push origin branch-name
```

Example:

```bash
git push origin backend-login
```

Your changes will now appear on GitHub under your branch.

---

# Pull Request Process

All changes must go through a Pull Request before being merged into `main`.

The workflow is:

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

A Pull Request should explain:

- What was changed
- Why it was changed
- How it was tested
- Any known issues

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

---

# Code Review Rules

When reviewing another team member's work, check:

- Does the code work?
- Is the code understandable?
- Is it placed in the correct folder?
- Could it break another system component?
- Has it been tested?

Code reviews are meant to improve the project and maintain quality.

---

# Files That Should Not Be Uploaded

Do not commit:

- Passwords
- API keys
- Database credentials
- Personal information
- Temporary files
- Generated build files

Examples:

```text
.env
credentials.txt
node_modules/
build/
.gradle/
venv/
```

These files should be added to `.gitignore`.

---

# Updating Your Branch

Before starting new work, update your branch with the latest version.

```bash
git pull origin main
```

This helps prevent conflicts with other team members' changes.

---

# Working on Existing Code

Before modifying another person's work:

1. Check if someone is already working on that section.
2. Communicate with the team.
3. Avoid changing unrelated files.

Example:

If you are assigned to:

```text
web-app/
```

do not modify:

```text
backend/
```

unless it has been discussed with the team.

---

# GitHub Issues

GitHub Issues should be used to track:

- Tasks
- Bugs
- Features
- Improvements

Examples:

```text
Bug: Vehicle detection crashes when uploading video

Feature: Add investigator search function

Task: Create database relationship diagram
```

Each issue should include:

- Description of the task
- Assigned team member
- Expected outcome

---

# General Rules

All contributors must:

- Work on their own branch.
- Avoid committing directly to `main`.
- Check changes before committing.
- Write meaningful commit messages.
- Test their work before pushing.
- Keep the repository organised.
- Communicate before making major changes.

---

# Final Reminder

The folder where you save the file is the folder where GitHub will place the file.

Git does not decide where files belong. Git records the file location when the commit is created.

Following this workflow will keep the Argus project organised and make collaboration easier for everyone.
