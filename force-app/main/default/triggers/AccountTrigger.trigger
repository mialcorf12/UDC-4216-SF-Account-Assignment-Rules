trigger AccountTrigger on Account (after insert, after update) {
    if (Trigger.isAfter && Trigger.isInsert) {
        System.enqueueJob(new AccountAssignmentRulesQueueable(new Map<Id, Account>(Trigger.new).keySet()));
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
        AccountTriggerHandler.handleDynamicUpdate(Trigger.new, Trigger.oldMap);
    }
}
/*
trigger AccountTrigger on Account (before update) {
    Set<Id> AccountIds = new Set<Id>();
    Map<Id, Account> MapofAccounts;// = new Map<Id, Account>();
    for(Account acc: Trigger.new){
        AccountIds.add(acc.Id);
        
    }
    
    if(AccountIds.size()>0){
        MapofAccounts = new Map<Id, Account>([SELECT ID, Name, Phone, Send_to_WebApp__c, (SELECT ID, firstName, Email FROM Contacts) FROM Account WHERE ID IN: AccountIds]);
        
    }
    
    for(Account accRecord: Trigger.new) {
        if(MapofAccounts.containsKey(accRecord.Id)){
            Account acc = MapofAccounts.get(accRecord.Id);
            if(accRecord.Send_to_WebApp__c && (accRecord.Phone== NULL|| accRecord.Name == '' ||
                                         ( acc.contacts.size()>0 && (acc.contacts[0].firstName=='' || acc.Contacts[0].Email == NULL) ))){
                                             accRecord.addError('Required fields are missing in Account and its related contact');
                                             
                                         }
        }
    }
}
*/