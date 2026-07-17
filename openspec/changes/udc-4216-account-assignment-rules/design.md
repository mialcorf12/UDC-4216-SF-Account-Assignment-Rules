# Design: UDC-4216 SF Account Assignment Rules

## Technical Approach
New standalone handler `AccountAssignmentRules` invoked directly from `AccountTrigger` on `after insert`. The existing `AccountTriggerHandler` handles `after update` — they are in separate trigger contexts, not parallel on the same event. Engine loads all MDT + supporting data ONCE via bulk queries, filters to SysAdmin-owned Accounts, then evaluates rules per-Account in ascending `Order__c`, first-match-wins. Matches accumulate into a single DML update (using `new Account(Id=acc.Id)` pattern to avoid mutating read-only Trigger.new records). Invalid/inactive owners are skipped with an email alert. Once OwnerId is set, the existing flow `Company_Integration_Specialist_Assignment` fires automatically on `RecordAfterSave` and handles specialist field assignment — no engine involvement needed.

## Architecture Decisions

| Decision | Options | Choice + Rationale |
|---|---|---|
| MDT load | `getAll()` vs SOQL `ORDER BY Order__c` | SOQL ordered — DB-guaranteed ordering, testable, respects Order__c contract; 18 rows, cost trivial |
| Owner validity | per-rule SOQL vs pre-query Map | Pre-query `Map<Id,User>` from all `OwnerId__c` — zero SOQL in loop |
| Matching | inline vs `matches()` helper | Private static `matches(rule, acc)` returning Boolean — keeps loop clean, unit-anchorable |
| Matching logic | AND vs OR between criteria | AND — all non-blank criteria must pass; blank=wildcard. Postal Code prefix is the only partial match allowed |
| Group lookup | `Group.Name` vs `Group.DeveloperName` | `DeveloperName = 'AccountAssignmentRule_Admins'` — stable API key (label has spaces) |
| Email isolation | inline vs separate method | `@TestVisible` static method — mockable via injectable flag in test context |
| Trigger.new mutation | mutate in-place vs new instance | `new Account(Id=acc.Id, OwnerId=x)` — Trigger.new is read-only in after-insert; mutating causes FinalException |
| Specialist fields | in engine vs delegated | Delegated to flow `Company_Integration_Specialist_Assignment` — fires on OwnerId change, no engine change needed |

## Data Flow
```
AccountTrigger (after insert)
  -> AccountAssignmentRules.assign(Trigger.new)
       1. Query Profiles (SysAdmin ids)        ] once
       2. Query owning Users by profile        ] before
       3. Query MDT ORDER BY Order__c          ] loop
       4. Build Map<Id,User> owner cache       ]
       5. Query GroupMember for alert emails   ]
       for each SysAdmin Account:
         for each rule (ordered):
           if isCatchAll(rule) -> skip
           if matches(rule, acc):          [AND logic, blank=wildcard]
             if ownerActive -> stage new Account(Id,OwnerId), break
             else -> log + alert, continue
       6. update List<Account>              (single DML)
  -> Flow: Company_Integration_Specialist_Assignment (RecordAfterSave)
       Entry: Account_Status__c='uLab Account' AND (OwnerId IsChanged OR specialist null)
       1. Get new Owner (User record)
       2. Get Primary IS User (Full_Name__c = Owner.Integration_Specialist__c)
       3. Get Secondary IS User (Full_Name__c = Owner.Development_Specialist__c)
       4. Update Integration_Specialist__c + Development_Specialist__c on Account

AccountTrigger (after update)
  -> AccountTriggerHandler.handleDynamicUpdate(Trigger.new, Trigger.oldMap)
```

## File Changes
| File | Action | Description |
|---|---|---|
| `objects/Account_Assignment_Rule__mdt/*` | Create | MDT def + 5 fields + `Require_Owner` VR |
| `customMetadata/Account_Assignment_Rule.*.md-meta.xml` | Create | 18 staging records |
| `classes/AccountAssignmentRules.cls` | Create | Engine — OwnerId assignment only |
| `classes/AccountAssignmentRulesTest.cls` | Create | Coverage >=85% |
| `triggers/AccountTrigger.trigger` | Modify | after insert -> AccountAssignmentRules; after update -> AccountTriggerHandler |
| `classes/AccountTriggerHandler.cls` | Retrieved | Tracked in source, logically unchanged |
| `flows/Company_Integration_Specialist_Assignment.flow-meta.xml` | Retrieved | Existing flow — no modification; documented for context |

## Interfaces / Contracts (Apex)
```apex
public with sharing class AccountAssignmentRules {
  public static void assign(List<Account> newAccounts);
  private static Boolean isCatchAll(Account_Assignment_Rule__mdt r);
  private static Boolean matches(Account_Assignment_Rule__mdt r, Account a);
  @TestVisible private static void sendInvalidOwnerAlert(String ruleOrder, String ownerId, List<String> alertEmails);
  @TestVisible static Boolean skipEmailInTest = false;
}
```
Matching (case-insensitive, blank=wildcard, AND logic): Country IN(csv) AND State IN(csv) AND PostalCode.startsWith(prefix). All non-blank criteria must pass. Debug logs: `se aplico la regla #{Order}`, `no cumplio con ninguna regla establecida`, `regla #{Order} fallida — OwnerId inválido: {Id}`.

## Testing Strategy (Strict TDD — RED first)
| Layer | Test | Approach |
|---|---|---|
| Unit | Country-only match (Sc1) | Insert Account as SysAdmin, assert OwnerId |
| Unit | Country+State (Sc2) | Assert OwnerId set |
| Unit | Country+State+Postal prefix (Sc3) | Assert OwnerId set |
| Unit | No match (Sc4) | Assert fields unchanged |
| Unit | Non-SysAdmin skip (Sc5) | Assert OwnerId unchanged |
| Unit | Catch-all skip (Sc6) | Assert never matches |
| Unit | Invalid Owner (Sc7) | Inactive user, assert skip+log; email suppressed via `@TestVisible` flag |
| Bulk | 200+ inserts | Single DML asserted, all 200 accounts matched |
| Priority | testLowestOrderWins | Two matching rules, assert only lowest Order applied |

## Threat Matrix
N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary. Pure Apex + Salesforce metadata + declarative flow.

## Migration / Rollout (Deployment Sequence)
1. **Public Group** `AccountAssignmentRule_Admins` (Setup, add Alberto Cordero) — manual prerequisite.
2. **MDT** definition + 5 fields + VR, then 18 records.
3. **Apex**: retrieve `AccountTrigger`+`AccountTriggerHandler`, add `AccountAssignmentRules` + test, modify trigger.
4. Deploy Apex with tests; validate against real Accounts; PO sign-off.
5. Flow `Company_Integration_Specialist_Assignment` fires automatically — no deployment needed.

## Open Questions
- None. All decisions resolved. Group DeveloperName confirmed as `AccountAssignmentRule_Admins`.
