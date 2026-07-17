# Proposal: UDC-4216 SF Account Assignment Rules

## Intent

Build a metadata-driven Account assignment engine for Salesforce to automate the assignment of Account Owner based on geographic criteria (Country, State, Postal Code) upon Account creation by SysAdmins. Integration Specialist and Development Specialist assignment is handled by the existing flow `Company_Integration_Specialist_Assignment`.

## Scope

### In Scope
- Custom Metadata Type (`Account_Assignment_Rule__mdt`) with 5 fields and `Require_Owner` validation rule
- Loading 18 staging MDT records
- Apex trigger handler class (`AccountAssignmentRules`) — OwnerId assignment only
- Wire `AccountAssignmentRules` to `AccountTrigger` on `after insert`
- Fetch existing `AccountTrigger` and `AccountTriggerHandler` from the Dev org
- Apex test class (`AccountAssignmentRulesTest`) with >= 85% coverage and bulk assertions
- Public Group setup task: `AccountAssignmentRule Admins` (DeveloperName: `AccountAssignmentRule_Admins`)
- Document existing flow `Company_Integration_Specialist_Assignment` and its interaction with `AccountAssignmentRules`

### Out of Scope
- `after update` trigger logic
- UI for rule management
- Any object other than Account
- CI/CD pipeline configuration
- `Integration_Specialist__c` and `Development_Specialist__c` assignment — delegated to existing flow `Company_Integration_Specialist_Assignment`

## Capabilities

### New Capabilities
- `account-assignment`: Metadata-driven assignment of OwnerId based on geographic criteria for SysAdmin Account inserts.

### Existing Capabilities Leveraged
- `specialist-assignment`: Flow `Company_Integration_Specialist_Assignment` fires on `RecordAfterSave` when OwnerId changes, reads specialist names from the new Owner's User fields, and populates `Integration_Specialist__c` + `Development_Specialist__c` on the Account automatically.

### Modified Capabilities
- None

## Approach

Create a new trigger handler class `AccountAssignmentRules` specifically for Owner assignment logic. It will query the `Account_Assignment_Rule__mdt` records once before iterating over the `after insert` Account records. For each Account inserted by a SysAdmin, it evaluates rules sequentially by `Order__c`. If a match is found (case-insensitive, blank=wildcard, postal prefix, catch-all skipped), it prepares a single DML update. If an invalid/inactive User ID is configured in the rule, it gracefully skips and sends an email alert to the `AccountAssignmentRule Admins` public group via a GroupMember email resolution. Once OwnerId is set, the existing flow handles specialist assignment automatically.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `Account_Assignment_Rule__mdt` | New | Custom metadata type — 5 fields |
| `Account_Assignment_Rule.mdt-meta.xml` records | New | 18 metadata records |
| `AccountAssignmentRules.cls` | New | Assignment engine — OwnerId only |
| `AccountAssignmentRulesTest.cls` | New | Test coverage |
| `AccountTrigger.trigger` | Modified | Wired to call new handler on after insert; existing after update handler unchanged |
| `AccountTriggerHandler.cls` | Retrieved | Tracked in source, logically unchanged |
| `Company_Integration_Specialist_Assignment` flow | Existing | Fires after OwnerId change; sets specialist fields — no modification needed |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| SOQL limits inside loop | Low | Query MDT and GroupMembers once outside the loop |
| Email alert to Public Group fails | Low | Resolve emails from GroupMember table to send to valid addresses |
| Match performance degrades with large MDT | Low | Max MDT records is small (18), Apex easily handles looping them |
| Trigger.new records read-only in after insert | Resolved | Create new Account(Id=acc.Id, OwnerId=x) for DML instead of mutating Trigger.new |

## Rollback Plan

Remove the `AccountAssignmentRules` handler invocation from `AccountTrigger`, delete the `AccountAssignmentRules` class, and optionally delete the MDT configurations. The flow is unaffected and remains active.

## Success Criteria

- [ ] Account OwnerId is successfully populated upon SysAdmin insertion per MDT rules.
- [ ] Flow `Company_Integration_Specialist_Assignment` fires automatically after OwnerId change and populates specialist fields.
- [ ] Non-SysAdmins bypass the assignment engine without error.
- [ ] Bulk inserts (200+ records) process efficiently within CPU and DML limits.
- [ ] Inactive Owner configurations trigger an email to the public group but do not crash the transaction.
