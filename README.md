# Argus Shield

**Real-Time Computer Vision Application for Suspect and Vehicle Intelligence Capture in CIT Robbery Investigations**

Argus Shield is a research and development project focused on creating an investigator-facing mobile system that uses computer vision, artificial intelligence, and data management techniques to extract, store, and query suspect and vehicle intelligence from cash-in-transit (CIT) robbery footage.

The system is designed to assist investigators by transforming video footage into structured, searchable intelligence while considering ethical, security, and privacy requirements.

> **Note:** The project's technology stack was revised after the initial planning phase. The application is now built as a **Flutter mobile app** backed by **Supabase**, rather than the original Android Studio (Java) + PHP web + custom Python backend design. See [Architectural Design](#architectural-design) below for details. Whether a separate **web application** will also be built is still being decided by the team — see the note under [`web/`](#web) for the current status.

---

# Project Overview

Argus Shield consists of several interconnected development areas:

* **Mobile Application** — Flutter (Dart) application, targeting both iOS and Android, used by citizens, investigators, and admins to interact with the system.
* **Backend (Supabase)** — Backend-as-a-service platform (built on PostgreSQL) providing authentication, auto-generated REST APIs, database, and file storage. Any custom server-side logic (e.g. Supabase Edge Functions) also lives here.
* **AI / Computer Vision** — Python-based computer vision models used to extract information (suspects, vehicles, weapons, license plates) from footage.
* **Web Application** *(status TBD)* — Not yet confirmed as part of the current scope. See [`web/`](#web) below.
* **Database** — Supabase/PostgreSQL schema, migrations, and row-level security (RLS) policies used to store and retrieve investigation data.
* **Diagrams** — Architecture diagrams (C4 model), entity relationship diagrams (ERD), use-case diagrams, and UI mockups/wireframes.

The three primary user roles are:

* **Citizens** — submit footage/evidence of CIT incidents.
* **Investigators / Law enforcement officers** — review structured intelligence and manage assigned cases.
* **Admins** — manage investigator accounts, assign cases, and oversee system-wide activity ("watchover" dashboard).

These components work together to provide an end-to-end system for processing and querying suspect and vehicle intelligence.

---

# Project Structure

```text
cit-event-capture/
│
├── mobile/
│   └── Flutter (Dart) application — iOS and Android
│
├── backend/
│   └── Supabase configuration, policies, and Edge Functions (TypeScript)
│
├── ai/
│   └── Computer vision models and AI processing (Python)
│
├── web/
│   └── Web application — status TBD, see note below
│
├── database/
│   └── Supabase/PostgreSQL schema, migrations and RLS policies
│
├── diagrams/
│   └── Architecture, ERD and use-case diagrams; UI mockups/wireframes
│
├── docs/
│   └── Research documents and project reports
│
├── tests/
│   └── Testing files, test scripts and test results
│
├── README.md
├── CONTRIBUTING.md
└── .gitignore
```

## Folder Responsibilities

### `mobile/`

Contains the Flutter (Dart) mobile application, targeting both iOS and Android from a single codebase.

This may include:

* Screens/UI (login, admin dashboard, investigator case board, citizen submission board)
* Widgets and shared UI components
* State management
* Supabase client integration (auth, data, storage)
* Mobile-specific configuration and assets

### `backend/`

Contains backend configuration and logic built around **Supabase**.

Supabase provides authentication (JWT-based), auto-generated PostgREST APIs for each database table, database hosting, and file storage — removing the need for a hand-rolled API server. This folder may include:

* Supabase project configuration
* Row-level security (RLS) policy definitions
* Supabase Edge Functions (TypeScript, Deno) for any custom server-side logic not covered by auto-generated APIs
* Integration glue between the mobile app, Supabase, and the AI/CV component

### `ai/`

Contains artificial intelligence and computer vision functionality, written in Python.

This may include:

* Computer vision models (e.g. YOLOv8-based detection)
* Image and video processing
* Object detection: weapons, vehicles, license plates
* Person/suspect detection
* Feature extraction
* Model configuration and related scripts

### `web/`

**Status: to be decided by the team.**

The original project plan included a PHP/HTML/CSS/JS web application for investigators. Since the pivot to a Flutter mobile app, it has not yet been decided whether a separate web application will still be built (e.g. as an admin/investigator portal) or whether the mobile app will cover all user roles. This folder is a placeholder until that decision is made — update this section once confirmed.

### `database/`

Contains database-related files for the Supabase/PostgreSQL database.

This may include:

* Table/schema definitions
* SQL migrations
* Seed data
* Row-level security (RLS) policies
* Database configuration

Do not store database passwords, service role keys, or other credentials in this directory.

### `diagrams/`

Contains architecture and design diagrams for the project.

This may include:

* C4 model diagrams (Level 1 context diagram, Level 2 container diagram)
* Entity Relationship Diagrams (ERD)
* Use-case diagrams
* UI mockups and wireframes (e.g. login, admin dashboard, investigator board, citizen submission board)

### `docs/`

Contains project documentation.

This may include:

* Research documentation
* Design documents
* Technical reports
* Project planning documents
* Deliverables (e.g. requirements and use-case descriptions)

### `tests/`

Contains testing-related files.

This may include:

* Flutter widget/unit tests
* Supabase/API integration tests
* AI model tests
* Test data
* Test results
* Automated testing scripts

---

# Requirements

Before starting development, ensure the required software for your assigned development area is installed.

General requirements include:

* Git
* Flutter SDK and Dart
* Android Studio (recommended IDE for Flutter development, with emulator support)
* Python 3.x (for AI/CV development)
* Supabase account and Supabase CLI
* Figma (for UI/UX prototyping, if contributing to design)

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
mobile/
backend/
ai/
web/
database/
diagrams/
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
feature/backend-auth-policies
feature/vehicle-detection
feature/investigator-dashboard
bugfix/mobile-camera-upload
database-schema
diagrams/erd-update
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
* Do not commit secrets or sensitive information (including Supabase keys).
* Communicate with the team before making major cross-component changes.
* Create a Pull Request before merging changes into `main`.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the full contribution process.

---

# Architectural Design

## Technology Stack

| Layer/Component | Technology | Purpose |
|---|---|---|
| UI/UX | Flutter (Dart) | Cross-platform mobile framework (iOS + Android) from a single codebase |
| Backend | Supabase | Backend-as-a-service on PostgreSQL — auth, auto-generated REST APIs, storage |
| AI/CV | Python | Computer vision and AI/ML libraries (e.g. OpenCV, TensorFlow, PyTorch) for footage analysis |
| Database | Supabase PostgreSQL | Relational database with row-level security |
| Authentication | JWT via Supabase | Token-based auth for secure API access between mobile app and backend |
| APIs | PostgREST (auto-generated by Supabase) | Standard REST communication between mobile app and backend |
| Edge Functions (if needed) | TypeScript (Deno, via Supabase) | Custom server-side logic beyond auto-generated APIs |
| UI/UX Prototyping | Figma | Collaborative design and prototyping |

## Development Environments / IDEs

* Android Studio — Flutter development and testing (emulators)
* Supabase — backend, database, and file storage hosting

## High-Level Technical Design

The high-level architecture follows the C4 model (Levels 1–2):

* **Level 1 — Context diagram:** how the system interacts with its users (citizens, investigators, admins) and external systems.
* **Level 2 — Container diagram:** the mobile app, Supabase backend, database, and AI/CV component as containers, including their responsibilities, relationships, and technologies.

See [`diagrams/`](#diagrams) for the current diagrams.

---

# Security and Privacy

Argus Shield deals with potentially sensitive investigation-related information.

Security and privacy must therefore be considered throughout development.

Never commit the following to the repository:

* Passwords
* Supabase API keys or service role keys
* Authentication tokens
* Database credentials
* Personal information
* Sensitive datasets
* Private investigation footage
* Hard-coded secrets
* Environment-specific credentials

Sensitive configuration should be stored using appropriate environment variables or other secure configuration mechanisms (e.g. Supabase project settings, `.env` files excluded from Git).

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

Project documentation should be stored in the `docs/` directory, with diagrams stored in `diagrams/`.

Examples include:

* System architecture (C4 diagrams)
* Database design and ERD
* UI mockups/wireframes
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

* Flutter widget and unit testing
* Supabase/API integration testing
* AI model testing
* Database testing (including RLS policy testing)
* Integration testing across mobile app, Supabase, and AI component

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
Database (Supabase/PostgreSQL)
      |
      v
Backend (Supabase)
      |
      v
Investigator Interface (Flutter mobile app)
```

The system should ultimately allow investigators to efficiently search, retrieve, and analyse relevant suspect and vehicle intelligence extracted from CIT robbery footage.

Development should maintain appropriate ethical, security, privacy, and responsible-AI considerations throughout the project. In particular, the system is designed as a decision-support tool: it does not determine guilt, make arrests, or take autonomous enforcement action — investigators remain responsible for reviewing and acting on system-generated intelligence.

---

# Repository Information

**Repository:** `cit-event-capture`

**Project Name:** Argus Shield

**Primary Branch:** `main`

**Project Type:** Research and Development

**Focus:** Computer Vision, Artificial Intelligence, Investigation Support, Data Management

---

This project is currently not licensed for redistribution.

The team should decide on the appropriate license before publicly distributing the project.
