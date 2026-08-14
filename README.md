# Argus Shield

**Real-Time Computer Vision Application for Suspect and Vehicle Intelligence Capture in CIT Robbery Investigations**

Argus Shield is a research and development project focused on creating an investigator-facing system that uses computer vision, artificial intelligence, and data management techniques to extract, store, and query suspect and vehicle intelligence from cash-in-transit (CIT) robbery footage.

The system is designed to assist investigators by transforming video footage into structured, searchable intelligence while considering ethical, security, and privacy requirements.

---

# Project Overview

Argus Shield consists of several interconnected development areas:

* **Android Application** — Java application developed using Android Studio for capturing and/or interacting with relevant investigation footage and data.
* **Python Backend** — Backend API responsible for communication, processing, business logic, and integration between system components.
* **AI / Computer Vision** — Computer vision models and artificial intelligence functionality used to extract information from footage.
* **Web Application** — HTML, CSS, JavaScript, and PHP application used by investigators to interact with the system.
* **Database** — Database structures, queries, scripts, and configuration used to store and retrieve investigation data.

These components work together to provide an end-to-end system for processing and querying suspect and vehicle intelligence.

---

# Project Structure

```text
cit-event-capture/
│
├── android/
│   └── Android Studio Java application
│
├── backend/
│   └── Python backend API and server logic
│
├── ai/
│   └── Computer vision models and AI processing
│
├── web/
│   └── HTML, CSS, JavaScript and PHP web application
│
├── database/
│   └── Database scripts, schemas and configuration
│
├── docs/
│   └── Research documents, diagrams and project reports
│
├── tests/
│   └── Testing files, test scripts and test results
│
├── README.md
├── CONTRIBUTING.md
└── .gitignore
```

## Folder Responsibilities

### `android/`

Contains the Android application developed using Java and Android Studio.

Android-specific code, resources, configuration, and related files should be placed here.

### `backend/`

Contains the Python backend API and server-side application logic.

This may include:

* API endpoints
* Request handling
* Authentication
* Business logic
* Communication with the database
* Communication with AI services
* Data processing

### `ai/`

Contains artificial intelligence and computer vision functionality.

This may include:

* Computer vision models
* Image processing
* Video processing
* Object detection
* Vehicle detection
* Person detection
* Feature extraction
* Model configuration and related scripts

### `web/`

Contains the investigator-facing web application.

This may include:

* HTML
* CSS
* JavaScript
* PHP
* Web pages
* User interfaces
* Investigator search functionality
* Data visualisation

### `database/`

Contains database-related files.

This may include:

* Database schemas
* SQL scripts
* Migrations
* Seed data
* Database configuration

Do not store database passwords, credentials, or other secrets in this directory.

### `docs/`

Contains project documentation.

This may include:

* Research documentation
* Architecture diagrams
* Database diagrams
* UML diagrams
* Design documents
* Technical reports
* Project planning documents

### `tests/`

Contains testing-related files.

This may include:

* Unit tests
* Integration tests
* API tests
* Test data
* Test results
* Automated testing scripts

---

# Requirements

Before starting development, ensure the required software for your assigned development area is installed.

General requirements include:

* Git
* Android Studio
* Java Development Kit (JDK)
* Python 3.x
* PHP development environment
* Database management software

Additional dependencies may be required depending on the component being developed.

Component-specific setup instructions should be documented in the relevant folder or in the project documentation.

---

# Getting Started

## 1. Clone the Repository

Clone the repository from GitHub:

```bash
git clone https://github.com/MeanBanana/cit-event-capture.git
```

Enter the project directory:

```bash
cd cit-event-capture
```

## 2. Read the Contribution Guidelines

Before making changes, read:

[CONTRIBUTING.md](./CONTRIBUTING.md)

This document explains:

* How to create and manage branches
* How to commit changes
* How to synchronise a feature branch with `main`
* How to resolve merge conflicts
* How to push changes
* How to create Pull Requests
* How code review works
* Security and repository rules

All contributors are expected to follow these guidelines.

## 3. Identify Your Development Area

Determine which part of the project you are working on:

```text
android/
backend/
ai/
web/
database/
docs/
tests/
```

Only modify files relevant to your assigned task unless you have communicated with the team about changes to another component.

---

# Git Workflow

The `main` branch represents the stable version of the project.

Contributors must **not commit directly to `main`**.

The standard workflow is:

```text
main
 |
 |-- Create feature branch
 |
 v
Feature Branch
 |
 |-- Make changes
 |
 |-- Commit changes
 |
 |-- Synchronise with main
 |
 |-- Resolve conflicts if necessary
 |
 |-- Test
 |
 |-- Push
 |
 v
Pull Request
 |
 v
Code Review
 |
 v
Approval
 |
 v
main
```

For the complete Git workflow, see:

[CONTRIBUTING.md](./CONTRIBUTING.md)

---

# Branch Naming

Branches should have descriptive names that indicate the area or purpose of the work.

Examples:

```text
feature/backend-login
feature/vehicle-detection
feature/investigator-dashboard
bugfix/android-camera
database-schema
documentation/project-architecture
```

Avoid vague branch names such as:

```text
test
new
changes
stuff
branch1
```

Before creating a branch, check that another team member is not already using the same branch.

---

# Development Guidelines

When contributing to Argus Shield:

* Work on your own branch.
* Do not commit directly to `main`.
* Pull the latest `main` before starting new work.
* Keep your branch synchronised with `main`.
* Place files in the correct project directory.
* Keep commits focused and descriptive.
* Test your changes before creating a Pull Request.
* Do not commit secrets or sensitive information.
* Communicate with the team before making major cross-component changes.
* Create a Pull Request before merging changes into `main`.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the full contribution process.

---

# Security and Privacy

Argus Shield deals with potentially sensitive investigation-related information.

Security and privacy must therefore be considered throughout development.

Never commit the following to the repository:

* Passwords
* API keys
* Authentication tokens
* Database credentials
* Personal information
* Sensitive datasets
* Private investigation footage
* Hard-coded secrets
* Environment-specific credentials

Sensitive configuration should be stored using appropriate environment variables or other secure configuration mechanisms.

The following types of files should generally be excluded using `.gitignore`:

```text
.env
credentials.json
passwords.txt
database_passwords.txt
node_modules/
build/
.gradle/
venv/
```

If sensitive information is accidentally committed, notify the team immediately rather than simply deleting it in a later commit.

---

# Documentation

Project documentation should be stored in the `docs/` directory.

Examples include:

* System architecture
* Database design
* UML diagrams
* API documentation
* Research
* Design decisions
* Testing documentation
* User documentation

The root `README.md` should contain information needed to understand and get started with the project.

Detailed technical documentation should generally be placed inside `docs/`.

---

# Testing

All contributors should test their changes before submitting a Pull Request.

Testing should be appropriate to the component being modified.

Examples include:

* Android application testing
* Backend API testing
* AI model testing
* Database testing
* Web application testing
* Integration testing

Test results should be documented where appropriate.

The `tests/` directory should contain reusable test code, scripts, and relevant testing resources.

Before creating a Pull Request, ensure that your changes:

* Work as expected.
* Do not introduce obvious regressions.
* Do not break other components.
* Have been tested in the appropriate environment.

---

# GitHub Issues

GitHub Issues should be used to track:

* Bugs
* Features
* Tasks
* Improvements
* Research items
* Technical problems

Each issue should clearly describe:

* What needs to be done.
* Why it needs to be done.
* The expected outcome.
* The team member responsible, where applicable.

Examples:

```text
Bug: Vehicle detection crashes when uploading video

Feature: Add investigator search functionality

Task: Create database relationship diagram

Research: Evaluate vehicle detection model performance
```

---

# Collaborators

* [Carel von Ronge](https://github.com/MeanBanana)
* [Deacon George Nel](https://github.com/Deacs-ifbb)
* Claire Aimee Duke
* Eliandro Cidy Gomez Miranda
* Melusi Sikakane

---

# Project Status

Argus Shield is currently under active research and development.

Individual components may be at different stages of development. Features should not be considered production-ready unless they have been implemented, tested, and reviewed by the team.

---

# Project Goal

The goal of Argus Shield is to create a computer vision-based intelligence application capable of assisting investigations by transforming video footage into structured, searchable suspect and vehicle information.

The project aims to combine:

```text
Video Footage
      |
      v
Computer Vision / AI
      |
      v
Information Extraction
      |
      v
Database
      |
      v
Backend API
      |
      v
Investigator Interface
```

The system should ultimately allow investigators to efficiently search, retrieve, and analyse relevant suspect and vehicle intelligence extracted from CIT robbery footage.

Development should maintain appropriate ethical, security, privacy, and responsible-AI considerations throughout the project.

---

# Repository Information

**Repository:** `cit-event-capture`

**Project Name:** Argus Shield

**Primary Branch:** `main`

**Project Type:** Research and Development

**Focus:** Computer Vision, Artificial Intelligence, Investigation Support, Data Management

---

# License

Add the project's chosen license here once the team has agreed on the appropriate licensing terms.

For example:

```text
This project is currently not licensed for redistribution.
```

The team should decide on the appropriate license before publicly distributing the project.
