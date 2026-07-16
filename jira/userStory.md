# UDC-4216: SF Account Assignment Rules

## Title
As a Sales Operations Admin, I want an Account assignment engine driven by Custom Metadata rules so that new Accounts are automatically assigned to the correct Owner based on geographic territory — without requiring any code changes.

---

## Description
Today, Account ownership must be assigned manually when an Account is created by a system profile, creating delays and inconsistencies across territories. This story implements a metadata-driven rule engine — `AccountAssignmentRules` — that evaluates geographic criteria (Country, State, Postal Code) in priority order and assigns the correct Owner in a single, bulkified `after insert` trigger. `AccountTrigger` already exists and calls `AccountTriggerHandler`; this story adds `AccountAssignmentRules` as an additional handler class called directly from `AccountTrigger` on `after insert`. Rules are managed entirely through Custom Metadata, allowing Admins to update territory coverage without touching code.

---

## Acceptance Criteria

### Scenario 1: Account created by SysAdmin — rule matches on Country only
```
Given a new Account is inserted in Salesforce
And the Account's OwnerId belongs to a user with profile 'uLab SysAdmin' or 'System Administrator'
And an active rule exists where BillingCountry__c is set, BillingState__c and BillingPostalCode__c are blank
When the AccountTrigger fires (after insert) and calls AccountAssignmentRules
And Account.BillingCountry matches (case-insensitive) any comma-separated value in BillingCountry__c
Then Account.OwnerId is set to OwnerId__c
And evaluation stops — no further rules are checked
And the debug log records: "se aplico la regla #[Order__c]"
```

### Scenario 2: Rule matches on Country AND State
```
Given a new Account is inserted by a SysAdmin profile
And a rule exists with BillingCountry__c and BillingState__c set, BillingPostalCode__c blank
When Account.BillingCountry matches any value in BillingCountry__c (case-insensitive)
And Account.BillingState matches any value in BillingState__c (case-insensitive)
Then the rule applies and fields are updated as in Scenario 1
And evaluation stops
```

### Scenario 3: Rule matches on State OR Postal Code prefix
```
Given a rule exists with BillingState__c and BillingPostalCode__c both set
When Account.BillingState matches any value in BillingState__c (case-insensitive)
OR Account.BillingPostalCode starts with any prefix listed in BillingPostalCode__c
Then the rule applies (OR logic — one match is sufficient)
And fields are updated as per the matched rule
And evaluation stops
```

### Scenario 4: No rules match
```
Given a new Account is inserted by a SysAdmin profile
And no active rule matches the Account's geographic criteria after evaluating all rules in Order__c sequence
When evaluation completes
Then Account.OwnerId remains unchanged
And the debug log records: "no cumplio con ninguna regla establecida"
```

### Scenario 5: Account NOT created by SysAdmin — engine skips
```
Given a new Account is inserted by a user whose profile is NOT 'uLab SysAdmin' or 'System Administrator'
When the AccountTrigger fires
Then AccountAssignmentRules does not execute
And no fields are modified
```

### Scenario 6: Catch-all rule (all geographic fields blank) — treated as no-match
```
Given a rule exists where BillingCountry__c, BillingState__c, and BillingPostalCode__c are all blank
When the engine evaluates that rule
Then the rule is explicitly skipped — it does NOT match any Account
And evaluation continues to the next rule in Order__c sequence
And if it is the last rule, behavior follows Scenario 4 (no change, debug log)
```

### Scenario 7: Rule matched but OwnerId__c references an inactive or deleted user
```
Given a matching rule is found
And OwnerId__c resolves to an inactive or non-existent Salesforce user
When the engine attempts to apply the rule
Then the assignment is NOT applied for that Account
And an email alert is sent to the Public Group 'AccountAssignmentRule Admins'
And the error is recorded in the debug log: "regla #[Order__c] fallida — OwnerId inválido: [Id]"
And evaluation continues to the next rule in Order__c sequence
```

### Salesforce Non-Functional AC
```
Given the trigger fires for a batch of 200+ Accounts
When AccountAssignmentRules processes the list
Then all MDT records are queried ONCE before any loop
And all Account updates are performed via a single DML statement at the end
And no SOQL queries exist inside any iteration
And CPU time stays below 80% of the 10,000ms limit

Given an unexpected runtime exception occurs during processing
When the error is caught
Then no partial DML is committed
And the error is logged for Admin review
```

---

## Matching Logic

| MDT fields populated | Logic applied |
| :--- | :--- |
| All blank | **Skipped explicitly** — treated as no-match |
| Country only | `Account.BillingCountry` IN Country values |
| Country + State | Country match **AND** State match |
| State + Postal Code | State match **OR** `BillingPostalCode.startsWith(prefix)` |
| Country + State + Postal Code | Country match **AND** (State match **OR** startsWith) |

**Rules:**
- **Blank field = wildcard** (ignored during evaluation), EXCEPT when ALL geographic fields are blank — that rule is explicitly skipped and never matches.
- **Starts With:** all values in `BillingPostalCode__c` are treated as prefixes regardless of length. Match is `Account.BillingPostalCode.startsWith(prefix)`.
- **Case-insensitive:** both sides are normalized before comparison.
- **First match wins:** rules are evaluated in ascending `Order__c` order; evaluation stops on the first matching rule.

---

## Technical Specifications

### 1. Custom Metadata Type

- **Singular Label:** Account Assignment Rule
- **Plural Label:** Account Assignment Rules
- **API Name:** `Account_Assignment_Rule__mdt`
- **Visibility:** Public
- **Description:** Defines geographic criteria for the automatic assignment of OwnerId on the Account object.

#### Fields

| Field Label | API Name | Data Type | Field Manageability | Description |
| :--- | :--- | :--- | :--- | :--- |
| Order | `Order__c` | Number(2, 0) — Required | Upgradable | Evaluation priority — lower number evaluated first. |
| Billing Country | `BillingCountry__c` | Text(255) | Upgradable | Comma-separated values (e.g. `Australia,AU,AUS`). Blank = wildcard. |
| Billing State | `BillingState__c` | Text(255) | Upgradable | Comma-separated values (e.g. `CA,California,AB,Alberta`). Blank = wildcard. |
| Billing Postal Code | `BillingPostalCode__c` | Long Text Area(2000) | Upgradable | Comma-separated prefixes for Starts With comparison (e.g. `936,937`). Blank = wildcard. |
| Owner Id | `OwnerId__c` | Text(18) | Upgradable | 18-character Salesforce ID of the new Account Owner. Required (see Validation Rule). |

#### Validation Rule

- **Name:** `Require_Owner`
- **Description:** Ensures OwnerId__c is always populated so the rule can assign a valid owner.
- **Error Formula:** `ISBLANK(OwnerId__c)`
- **Error Message:** "An Owner ID is required to save this rule."

---

### 2. Apex Handler Class

- **Class name:** `AccountAssignmentRules`
- **Called from:** `AccountTrigger` on `after insert` (alongside the existing `AccountTriggerHandler` call)
- **Bulkified:** processes `List<Account>`; all MDT records queried once before the loop; single DML update at the end
- **Profile filter:** only Accounts whose current OwnerId belongs to a user with profile `'uLab SysAdmin'` or `'System Administrator'` are processed
- **Case normalization:** both MDT values and Account field values are lowercased before comparison
- **Catch-all detection:** a rule where all three geographic fields are blank is skipped explicitly before any matching logic runs
- **Invalid OwnerId handling:** if OwnerId__c does not resolve to an active User, skip the rule, send an email alert to Public Group `'AccountAssignmentRule Admins'` (resolved at runtime via `GroupMember` → `User.Email` query), log the error, and continue to the next rule

---

### 3. Email Alert — Implementation Note

Apex's `Messaging.SingleEmailMessage` cannot address a Public Group by ID directly. The implementation must:
1. Query `GroupMember` where `Group.Name = 'AccountAssignmentRule Admins'` to retrieve member `User.Email` values.
2. Pass those addresses to `setToAddresses()`.

This keeps the recipient list dynamic — any future membership changes in Setup are picked up automatically without code changes.

> **Prerequisite:** The Public Group `AccountAssignmentRule Admins` must be created in Setup and Alberto Cordero added as a member **before** deploying the Apex class. If the group does not exist, the `GroupMember` query returns empty and the alert is silently skipped.

---

## Out of Scope
- `after update` trigger — reassignment when Owner is manually changed (separate story)
- Proactive validation of User IDs in MDT records at save time
- UI for rule management (Admins use Setup → Custom Metadata directly)
- Any object other than Account
- `Integration_Specialist__c` and `Development_Specialist__c` assignment — handled by the existing flow `Company_Integration_Specialist_Assignment`

---

## Story Points
**8 points** — Custom Metadata Type (5 fields + validation rule) + `AccountAssignmentRules` handler with 3-scenario matching engine + case-insensitive normalization + explicit catch-all detection + inactive User validation + email alert via GroupMember query + test class covering all 7 scenarios + bulk scenario (200+ records).

---

## Subtasks
1. Create `Account_Assignment_Rule__mdt` with 5 fields and `Require_Owner` validation rule
2. Load the 17 staging MDT records into the target org (OwnerId__c only; specialist fields removed)
3. Create Public Group `AccountAssignmentRule Admins` in Setup and add Alberto Cordero as initial member
4. Create `AccountAssignmentRules` Apex class — matching engine (Scenarios A/B/C), case-insensitive normalization, catch-all detection, inactive OwnerId detection, GroupMember email query, `Messaging.SingleEmailMessage` (OwnerId assignment only)
5. Wire `AccountAssignmentRules` into existing `AccountTrigger` on `after insert` (alongside existing `AccountTriggerHandler` call)
6. Write `AccountAssignmentRulesTest` — scenarios: bulk 200+ (happy path), no match, non-SysAdmin skip, catch-all skip, invalid OwnerId email alert, matching scenarios A / B / C
7. Deploy to sandbox, validate all 17 MDT records with real Account data, obtain PO sign-off
