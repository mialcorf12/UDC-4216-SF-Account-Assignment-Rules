# Apply Progress: UDC-4216 SF Account Assignment Rules

**Change**: udc-4216-account-assignment-rules
**Mode**: Standard (stacked-to-main)
**Branch**: main
**Last updated**: 2026-07-17
**Status**: All code phases complete ✅

---

## Completed Code Phases

### PR 1 — Phase 1, 2, 3 (Metadata + Records)

- [x] 1.2 Retrieve AccountTrigger + AccountTriggerHandler from Dev org
- [x] 1.3 Verify retrieved files; committed as-is
- [x] 1.4 Retrieve flow Company_Integration_Specialist_Assignment for documentation
- [x] 2.1–2.6 Created MDT object-meta.xml + 5 fields (Order__c, BillingCountry__c, BillingState__c, BillingPostalCode__c, OwnerId__c)
- [x] 2.7 Created Require_Owner.validationRule-meta.xml
- [x] 2.8 Deployed MDT definition → Succeeded
- [x] 3.1 Created all 18 Account_Assignment_Rule__mdt.Rule_*.md-meta.xml files (Rule_1 through Rule_18)
- [x] 3.2 Deployed MDT records → Succeeded
- [x] 3.4 Removed Integration_Specialist__c and Development_Specialist__c values from 13 records — commit 9097d42
- [x] 3.5 Updated several OwnerId values — commit 159209d

### PR 2 — Phase 4 (RED) + Phase 5 (GREEN)

- [x] 4.1–4.2 Written AccountAssignmentRulesTest.cls — 12 test methods — commit 9161e5d
- [x] 5.1–5.2 Written AccountAssignmentRules.cls — OwnerId-only engine — commit d4bc416
- [x] 5.3 Refactored: removed all specialist field logic — commit 9097d42
- [x] 5.4 All 12 tests PASS (100% pass rate), 91% coverage

### PR 3 — Phase 6 (Trigger Wiring)

- [x] 6.1 AccountTrigger: after insert → AccountAssignmentRules; after update → AccountTriggerHandler
- [x] 6.2 Fixed FinalException: Record is read-only — new Account(Id=acc.Id) pattern
- [x] 6.3 Deployed → Succeeded — commit fcbd70c
- [x] 6.4 12/12 tests PASS after fix

### Deploy to Staging

- [x] 7.1 Smoke test: BillingCountry=Australia → OwnerId Match: true
- [x] 7.2 Deployed to staging — commit a4a8219

---

## Pending Tasks (Org / Validation)

- [ ] 7.3 Create Public Group `AccountAssignmentRule Admins` (DeveloperName: `AccountAssignmentRule_Admins`) in Setup; add Alberto Cordero
- [ ] 7.4 Validate all 18 MDT records with real Account data in sandbox
- [ ] 7.5 Confirm flow `Company_Integration_Specialist_Assignment` fires after OwnerId assignment and populates specialist fields
- [ ] 7.6 PO sign-off + deploy to production

---

## Post-Deploy Refactor Summary (2026-07-16)

### What Changed
Removed `Integration_Specialist__c` and `Development_Specialist__c` from the entire project scope.

### Why
These fields are on the Account object (Lookup to User). Assignment is handled by the existing flow `Company_Integration_Specialist_Assignment` which fires on `RecordAfterSave` when OwnerId changes. The engine does not need to touch them.

### Files Affected
- `objects/Account_Assignment_Rule__mdt/fields/` — fields deleted
- `customMetadata/` — field values removed from 13 records
- `classes/AccountAssignmentRules.cls` — specialist assignment logic removed
- `classes/AccountAssignmentRulesTest.cls` — test scenarios updated
- `jira/userStory.md` — Out of Scope section updated

---

## Flow Documentation: Company_Integration_Specialist_Assignment

### Type
AutoLaunched, RecordAfterSave (Create and Update)

### Entry Criteria
**Filter logic**: `1 AND (2 OR 3 OR 4)`

| # | Field | Operator | Value |
| :--- | :--- | :--- | :--- |
| 1 | `Account_Status__c` | Equals | `uLab Account` |
| 2 | `OwnerId` | Is Changed | `true` |
| 3 | `Integration_Specialist__c` | Is Null | `true` |
| 4 | `Development_Specialist__c` | Is Null | `true` |

### Flow Steps

| Step | Label | What it does |
| :--- | :--- | :--- |
| 1 | Get new Owner | Queries the `User` record of the Account's current Owner (`$Record.Owner.Id`) to read the Owner's `Integration_Specialist__c` and `Development_Specialist__c` fields (custom fields on the User object). |
| 2 | Get Primary IS User | Queries the `User` record whose `Full_Name__c` matches the Owner's `Integration_Specialist__c` value — resolves the name to a User ID. |
| 3 | Get Secondary IS User | Queries the `User` record whose `Full_Name__c` matches the Owner's `Development_Specialist__c` value — resolves the name to a User ID. |
| 4 | Update Integration Specialist Fields | Updates `$Record.Integration_Specialist__c` and `$Record.Development_Specialist__c` with the IDs obtained in steps 2 and 3. |

### Interaction with AccountAssignmentRules

```
after insert
  └─ AccountAssignmentRules.assign()   → sets Account.OwnerId
  └─ Flow (RecordAfterSave)            → OwnerId changed → reads new Owner's specialist fields
                                       → sets Integration_Specialist__c + Development_Specialist__c
```

Because the flow triggers on `OwnerId IsChanged`, the Owner assignment made by `AccountAssignmentRules` automatically kicks off the specialist assignment on the same transaction's after-save phase — no additional code or coordination required.

### Pending Modification
None required for current scope. Flow fires automatically when OwnerId changes.

---

## Key Discoveries

1. **Trigger.new records are read-only in after-insert context**: Mutating acc.OwnerId caused `FinalException: Record is read-only`. Fix: `new Account(Id = acc.Id, OwnerId = ruleOwnerId)` for DML.
2. **Bug was latent in PR 2**: Tests called assign() directly (not via trigger), hiding the read-only constraint. Wiring the trigger exposed it immediately.
3. **Comma-separated metadata flag in sf CLI**: `-m "ApexClass:X,ApexTrigger:Y"` fails. Correct: `-m "ApexClass:X" -m "ApexTrigger:Y"`.
4. **Matching logic is AND, not OR**: All non-blank geographic criteria must pass. Blank fields are wildcards.
5. **Group query uses DeveloperName**: `Group.DeveloperName = 'AccountAssignmentRule_Admins'` — label has spaces, DeveloperName has underscores.

---

## Git Commits

| Commit | Description |
|--------|-------------|
| `862cb90` | feat: add Account_Assignment_Rule__mdt custom metadata type |
| `48b9939` | feat: retrieve AccountTrigger and AccountTriggerHandler from org |
| `6eadb34` | feat: load 17 Account Assignment Rule staging records |
| `9161e5d` | feat: add AccountAssignmentRulesTest RED phase |
| `d4bc416` | feat: implement AccountAssignmentRules engine with full test coverage |
| `fcbd70c` | feat: wire AccountAssignmentRules into AccountTrigger after insert |
| `9097d42` | refactor: remove Integration_Specialist__c and Development_Specialist__c from MDT and engine |
| `159209d` | several Account_Assignment_Rule__mdt ownerids updated |
| `a4a8219` | Deploy to staging |

---

## Current State Summary

✅ All code phases complete
✅ 12/12 tests pass, 91% coverage
✅ Staging deploy complete
⏳ Pending: Public Group creation, sandbox validation, flow confirmation, PO sign-off
