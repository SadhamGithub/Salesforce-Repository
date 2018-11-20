/**
 * Author : Natarajan Periyasamy
 * Date: 08/03/2018
 * Description: Opportunity Trigger Handler Methods
 */
public with sharing class CXT_OpportunityHelper extends TriggerHandler.TriggerHandlerBase {

    static String SPONSORED_DELEGATES = 'Sponsored Delegates';
    public Static String PASS_DELEGATE_REGISTRATION = 'Delegate_Registration';
    public static boolean ADJUSTED_WEIGHTAGE = false;
    public static Boolean run = true;

    private static Map<Id, List<CXT_Pass_Registration__c>> opportunityPassRegistrationMap  = new Map<Id, List<CXT_Pass_Registration__c>>();
    private static Map<Id, List<OpportunityLineItem>> oliByOppIdMap  = new Map<Id, List<OpportunityLineItem>>();

    public override void beforeInsert(List<SObject> lstNewSObjs) {

        System.debug('*******>>>>>>>>>>>>>>>> BEFORE INSERT OPPORTUNITY HANDLER <<<<<<<<<************');

        //Do Not Execute This Code If The Code Is Invoked By Queueable apex Job
        //Pass Registration Delegate Name Change / Status Changes Updates Opportunity In Queueable Context
        if(!System.isQueueable()) {
            populateBookingContact((List<Opportunity>)lstNewSObjs);
        }
        
        populateEmailForJuryRegType((List<Opportunity>)lstNewSObjs);
       
        onArchiveOpportunityInsert((List<Opportunity>)lstNewSObjs);
        Util.systemLimits();
    }

    public override void beforeUpdate(Map<Id,SObject> mapOldSObjs, Map<Id,SObject> mapNewSObjs) {

        System.debug('*******>>>>>>>>>>>>>>>> BEFORE UPDATE OPPORTUNITY HANDLER <<<<<<<<<************');

        //Do Not Execute This Code If The Code Is Invoked By Queueable apex Job
        //Pass Registration Delegate Name Change / Status Changes Updates Opportunity In Queueable Context
        if(!System.isQueueable()) {
            populateBookingContact(mapNewSObjs.values());
            populateProductsSummary((Map<Id, Opportunity>)mapNewSObjs);
        }
        
        //This Method Should Be Executed From Both Queueable / Non Queueable Context

        populateEmailForJuryRegType(mapNewSObjs.values());
        populatePaidPassesThatNeedsEmailSent((Map<Id, Opportunity>)mapOldSObjs, (Map<Id, Opportunity>)mapNewSObjs);
        onArchiveOpportunityUpdate((Map<Id, Opportunity>)mapOldSObjs, (Map<Id, Opportunity>)mapNewSObjs);
      
        Util.systemLimits();
    }

    public override void afterUpdate(Map<Id,SObject> mapOldSObjs, Map<Id,SObject> mapNewSObjs) {

        System.debug('*******>>>>>>>>>>>>>>>> AFTER UPDATE OPPORTUNITY HANDLER <<<<<<<<<************');

        //Do Not Execute This Code If The Code Is Invoked By Queueable apex Job
        //Pass Registration Delegate Name Change / Status Changes Updates Opportunity In Queueable Context
        if(!System.isQueueable()) {
            
            //Update Pass Registration Only When Certain Criteria Is Met, Not Always
           
            CreateOpportunityContactRoleQueueable createContactRoleQ = new CreateOpportunityContactRoleQueueable((Map<Id, Opportunity>)mapOldSObjs, (Map<Id, Opportunity>)mapNewSObjs);
            System.enqueueJob(createContactRoleQ);

            if(!ADJUSTED_WEIGHTAGE) {
                adjustOLIsForFreePasses(closedWinOppIds((Map<Id, Opportunity>)mapOldSObjs, (Map<Id, Opportunity>)mapNewSObjs));
            }

            updateRelatedPassRegistration((Map<Id, Opportunity>)mapOldSObjs, (Map<Id, Opportunity>)mapNewSObjs);
            createAssetOnOpportunityUpdate((Map<Id, Opportunity>)mapOldSObjs, (Map<Id, Opportunity>)mapNewSObjs, 'Closed Won');
        }

        Util.systemLimits();

        run = false;
    }

    @InvocableMethod(label='Update Opportunity Contact InUse' description='Returns the list of Contact InUse  corresponding to the specified Opportunity IDs.')
    public static void updateOpportunityContactInUse(List<Id> opportunityListIds){
        Set<Id> opportunitySetId = new Set<Id>(opportunityListIds);
        if(!System.isQueueable() && !System.isBatch() && !System.isFuture()) {
            ContactInUseHelper.opportunityContactInUse(opportunitySetId);
        }
    }

    public static void onArchiveOpportunityInsert(List<Opportunity> opportunityList) {

        Id archiveRecordTypeId = Util.getRecordTypeIdByDevName('Opportunity', 'Archive');
        Id archiveRenewalRecordTypeId = Util.getRecordTypeIdByDevName('Opportunity', 'Archive_Renewal');

        for(Opportunity thisOpportunity : opportunityList) {

            if(thisOpportunity.RecordTypeId == archiveRecordTypeId) {
                ArchiveOpportunityHelper.upadateRPIToBeApplied(thisOpportunity);
                ArchiveOpportunityHelper.populateRenewalPricingModel(thisOpportunity);
                ArchiveOpportunityHelper.updateCloseDate(thisOpportunity);
            } 
        }
    }

    public static void onArchiveOpportunityUpdate(Map<Id, Opportunity> opportunityOldMap, Map<Id, Opportunity> opportunityNewMap) {
        System.debug('opportunityOldMap' + opportunityOldMap);
        System.debug('opportunityNewMap' + opportunityNewMap);
       
        Map<Id,Event> eventMap  =new Map<Id, Event>();
        Set<Id> pricebookIds    = new Set<Id>();
        Set<Id> accountIds      = new Set<Id>();
        Set<Id> opportunityIds  = new Set<Id>();

        Id archiveRecordTypeId = Util.getRecordTypeIdByDevName('Opportunity', 'Archive');
        Id archiveRenewalRecordTypeId = Util.getRecordTypeIdByDevName('Opportunity', 'Archive_Renewal');
        Map<Id, Opportunity> opportunityMap = new Map<Id, Opportunity>();
        Map<Id, Id> oldToNewOpportunityMap = new Map<Id, Id>();
        Map<Id, PriceBook2> pricebook2Map = new Map<Id, PriceBook2>();

        Set<Id> closedWonUpsellOppIds = new Set<Id>();
        Set<Id> prevClosedWonOppIds = new Set<Id>();
        Set<Id> allArchiveOpportunityIds = new Set<Id>();

        for(Opportunity thisOpportunity : opportunityNewMap.values()) {
            if(thisOpportunity.RecordTypeId == archiveRecordTypeId
                || thisOpportunity.RecordTypeId == archiveRenewalRecordTypeId) {

                if(thisOpportunity.PriceBook2Id != null) {
                    pricebookIds.add(thisOpportunity.PriceBook2Id);
                }

                if(thisOpportunity.StageName == 'Closed Won'
                    && opportunityOldMap.get(thisOpportunity.Id).StageName != thisOpportunity.StageName) {

                    //If Renewal Upsell Users Closed Won, Then Update Quantity In Asynchronous Way
                    if(thisOpportunity.Type == 'Renewal Upsell (Users)') {
                        closedWonUpsellOppIds.add(thisOpportunity.Id);
                    }
                    else {
                        //If Renewal Upsell, Don't Update Account Classification
                        accountIds.add(thisOpportunity.AccountId);
                        opportunityIds.add(thisOpportunity.Id);

                        if(thisOpportunity.Previous_Opportunity__c != null) {
                            prevClosedWonOppIds.add(thisOpportunity.Previous_Opportunity__c);
                        }
                    }
                }

                //Collect All Archive Opportunity Ids To Validate Before Executing SOQL Queries / For Loops Below
                allArchiveOpportunityIds.add(thisOpportunity.Id);
            }
        }
        //Below Code Will execute Only If Archive Opportunity Is Created / Updated.
        //Will Not Be Fired For Other Opprotunity Record Types
        if(!pricebookIds.isEmpty()
            && !allArchiveOpportunityIds.isEmpty()) {
            pricebook2Map = new Map<Id, PriceBook2>([SELECT Id, Name, CXT_Festival__r.Name FROM PriceBook2 WHERE ID IN: pricebookIds]);
        }

        if(!allArchiveOpportunityIds.isEmpty()){
        
            for(Event thisEvent : [SELECT WhatId, Id, Type, Subject FROM Event 
                                                            WHERE WhatId =: allArchiveOpportunityIds
                                                            AND (Type = 'Discovery'
                                                            OR  Type = 'Workshop')]){

                eventMap.put(thisEvent.WhatId, thisEvent);
            }

            for(Opportunity thisOpportunity : opportunityNewMap.values()) {
                if(thisOpportunity.RecordTypeId == archiveRecordTypeId
                    || thisOpportunity.RecordTypeId == archiveRenewalRecordTypeId) {

                    ArchiveOpportunityHelper.validateRecord(thisOpportunity, eventMap);

                    Opportunity paidOpportunity = ArchiveOpportunityHelper.paidArchiveOpportunities(thisOpportunity, opportunityOldMap);

                    if(paidOpportunity != null) {
                        opportunityMap.put(paidOpportunity.Id, paidOpportunity);
                    }

                    if(thisOpportunity.PriceBook2Id != null) {
                        ArchiveOpportunityHelper.populateSubscriptionProductType(thisOpportunity, pricebook2Map);
                    }

                    if(thisOpportunity.RecordTypeId == archiveRecordTypeId) {
                        ArchiveOpportunityHelper.upadateRPIToBeApplied(thisOpportunity);
                        ArchiveOpportunityHelper.populateRenewalPricingModel(thisOpportunity);
                    } 
                }
            }
        }
        
        //Create Order Group For Paid Archive Opportunities - Only When Paid Is Changed And Is True
        if(!opportunityMap.isEmpty()){
            CreateOrderGroup.createArchiveOpportunityOrderGroup(opportunityMap);
        }

        //Update Account On Stage Change i.e, On Closed Won Archive
        if(!accountIds.isEmpty()
            && !opportunityIds.isEmpty()) {
            ArchiveOpportunityHelper.updateAccountClassification(accountIds , opportunityIds, prevClosedWonOppIds);
        }

        //Async Update - Only When MidTerm Upsell Archive Opportunity Is Closed Won And Stage Changed
        if(!closedWonUpsellOppIds.isEmpty()) {
            ArchiveOpportunityHelper.updateOpenRenewalWithNewQuantity(closedWonUpsellOppIds);
        }
    }

     /**
     * Populate Email Fields From Booking Contact If Registration Type Is JURY
     */
    public static void populateEmailForJuryRegType(List<Opportunity> oppList){
        Set<Id> conIds = new Set<Id>();
        Map<Id,String> contactMap = new Map<Id,String>();

        for(Opportunity oppVar : oppList){
            if(oppVar.CXT_Booking_Contact__c != null){
                conIds.add(oppVar.CXT_Booking_Contact__c);
            }
        }
        for(Contact conVar : [SELECT Id,CXT_Imported_Assistant_Email__c FROM Contact WHERE Id IN :conIds]){
            if(conVar.CXT_Imported_Assistant_Email__c != null){
                contactMap.put(conVar.Id, conVar.CXT_Imported_Assistant_Email__c.trim());
            }
        }

        for(Opportunity oppVar : oppList){
            if(oppVar.Registration_Type__c == 'Jury'){
                oppVar.Send_To_Preview_Email_Address__c = 'elizabeths@canneslions.com';
                if(contactMap.containsKey(oppVar.CXT_Booking_Contact__c)){
                    oppVar.Email_Confirmation_Contact__c = contactMap.get(oppVar.CXT_Booking_Contact__c);
                }
            }
        }
    }

    /**
     * Collect Closed Win Opportunitiy Id
     */
    public static Set<Id> closedWinOppIds(Map<Id, Opportunity> oppOldMap, Map<Id, Opportunity> oppNewMap) {
        Set<Id> oppIds = new Set<Id>();
        for(Opportunity opp : oppNewMap.values()) {
            if(opp.IsWon && !oppOldMap.get(opp.Id).IsWon) {
                oppIds.add(opp.Id);
            }
        }

        return oppIds;
    }
    
    /**
     * populate Booking Contact Method that copies Login contact if present in the Booking contact
     * @param oppNewMap new map of opportunity records
    */
    public static void populateBookingContact(List<Opportunity> oppNewList) {
        for(Opportunity opp: oppNewList) {
            if(opp.CXT_Booking_Contact__c == null && opp.Login_Contact__c != null) {
                opp.CXT_Booking_Contact__c = opp.Login_Contact__c;
            }
        }
    }
    
    /**
     * populatePaidPassesThatNeedsEmailSent Booking Confirmation Logic - Populates the number of passes paid / processed
     * @param oppNewMap Old Map of sObject Opportunity
     * @param oppOldMap New Map of sObject Opportunity
     */

    public static void populatePaidPassesThatNeedsEmailSent(Map<Id, Opportunity> oppOldMap, Map<Id, Opportunity> oppNewMap) {

        List<CXT_Pass_Registration__c> passRegistrationList = new List<CXT_Pass_Registration__c>();

        Map<Id, String> mapOppPassReg =  new Map<Id, String>();
        Map<Id, String> mapOppProcessedPassReg =  new Map<Id, String>();
        Map<Id, String> mapOppInProcessedPassReg =  new Map<Id, String>();
        Map<Id, String> mapOppPaidPassReg =  new Map<Id, String>();
        String isBadgePrinted = 'No';

        Send_Booking_Confirmation_Email__mdt bcMdt = [SELECT 
                                                        Opportunity_Record_Type__c,
                                                        Pass_Registration_Payment_Status__c,
                                                        Pass_Registration_Processing_Status__c,
                                                        Pass_Registration_Products_To_Exclude__c,
                                                        Pass_Registration_In_Processing_Status__c
                                                    FROM Send_Booking_Confirmation_Email__mdt LIMIT 1];

        Set<String> passRegPaymentStatus = new Set<String>(bcMdt.Pass_Registration_Payment_Status__c.split(','));
        Set<String> passRegProcessingStatus = new Set<String>(bcMdt.Pass_Registration_Processing_Status__c.split(','));
        Set<String> passRegInProcessingStatus = new Set<String>(bcMdt.Pass_Registration_In_Processing_Status__c.split(','));
        Set<String> proNameToExclude = new Set<String>(bcMdt.Pass_Registration_Products_To_Exclude__c.split(','));
        Set<String> oppRecordType = new Set<String>(bcMdt.Opportunity_Record_Type__c.split(','));

        Set<Id> recordTypeIds = new Set<Id>();
        Set<Id> opportunityIds = new Set<Id>();
        Set<Id> allOpportunityIds = new Set<Id>();

        //Send Booking Email Only For Configured Record Types
        for(String recName : oppRecordType) {
            recordTypeIds.add(Util.getRecordTypeIdByDevName('Opportunity', recName));
        }

        for(Opportunity opp: oppNewMap.Values()) {

            if(opp.StageName == 'Closed Won' 
                && oppOldMap.get(opp.Id).StageName != 'Closed Won'
                && opp.Opportunity_Close_Date_Time__c == null) {
                opp.Opportunity_Close_Date_Time__c = System.today();
            }

            if((!opp.Resend_Confirmation__c && oppOldMap.get(opp.Id).Resend_Confirmation__c)
                 || (opp.Send_Confirmation_Email__c && !opp.Resend_Confirmation__c)) {
                opp.Paid_Passes_that_Need_Email_Sent__c = 0;
            } 
            else {
                //If Resend Confirmation Is Set To True, Then Set Sent Confirmation Emails To False
                opp.Send_Confirmation_Email__c = false;

                //If Sent Confirmation Emails Is False, Then Populate The Paid Passes That Needs Email Sent Value
                if(recordTypeIds.contains(opp.RecordTypeId)
                    && !opp.Send_Confirmation_Email__c) {
                    opportunityIds.add(opp.Id);
                }
                allOpportunityIds.add(opp.Id);
            }
        }

        if(!opportunityIds.isEmpty() || !allOpportunityIds.isEmpty()) {
            for(AggregateResult ar: [SELECT COUNT(Id), CXT_Opportunity_Name__c FROM CXT_Pass_Registration__c WHERE CXT_Opportunity_Name__c IN: allOpportunityIds GROUP BY CXT_Opportunity_Name__c]) {
                mapOppPassReg.put( (String) ar.get('CXT_Opportunity_Name__c'),  String.valueOf(ar.get('expr0')));
            }

            for(AggregateResult ar: [SELECT COUNT(Id), CXT_Opportunity_Name__c FROM CXT_Pass_Registration__c WHERE CXT_Opportunity_Name__c IN: opportunityIds AND CXT_Product_Name__r.Name NOT IN: proNameToExclude AND CXT_Registration_Status__c IN: passRegProcessingStatus GROUP BY CXT_Opportunity_Name__c]) {
                mapOppProcessedPassReg.put( (String) ar.get('CXT_Opportunity_Name__c'),  String.valueOf(ar.get('expr0')));
            }

            for(AggregateResult ar: [SELECT COUNT(Id), CXT_Opportunity_Name__c FROM CXT_Pass_Registration__c WHERE CXT_Opportunity_Name__c IN: opportunityIds AND CXT_Product_Name__r.Name NOT IN: proNameToExclude AND CXT_Payment_Status_2__c IN: passRegPaymentStatus AND Badge_Printed__c =: isBadgePrinted AND Date_Badge_Printed__c = null GROUP BY CXT_Opportunity_Name__c]) {
                mapOppPaidPassReg.put( (String) ar.get('CXT_Opportunity_Name__c'),  String.valueOf(ar.get('expr0')));
            }

            for(AggregateResult ar: [SELECT COUNT(Id), CXT_Opportunity_Name__c FROM CXT_Pass_Registration__c WHERE CXT_Opportunity_Name__c IN: opportunityIds AND CXT_Product_Name__r.Name NOT IN: proNameToExclude AND CXT_Registration_Status__c IN: passRegInProcessingStatus GROUP BY CXT_Opportunity_Name__c]) {
                mapOppInProcessedPassReg.put( (String) ar.get('CXT_Opportunity_Name__c'),  String.valueOf(ar.get('expr0')));
            }
        }
        
        //Populate The Paid Passes That Needs Email Sent
        for(Opportunity opp: oppNewMap.Values()) {
            if(!opp.Send_Confirmation_Email__c) {
                opp.Total_No_of_Pass_Registrations__c           = mapOppPassReg.get(opp.Id) != null ? Integer.ValueOf(mapOppPassReg.get(opp.Id)) : 0;
                opp.Total_No_of_Processed_Pass_Registrations__c = mapOppProcessedPassReg.get(opp.Id) != null ? Integer.ValueOf(mapOppProcessedPassReg.get(opp.Id)) : 0;
                opp.No_of_Pass_Registrations_In_Processing__c   = mapOppInProcessedPassReg.get(opp.Id) != null ? Integer.ValueOf(mapOppInProcessedPassReg.get(opp.Id)) : 0;
                opp.Paid_Passes_that_Need_Email_Sent__c         = mapOppPaidPassReg.get(opp.Id) != null ? Integer.ValueOf(mapOppPaidPassReg.get(opp.Id)) : 0;
            }
        }
    }

    /**
     * populateProductsSummary Populate The Product Summary
     * @param oppNewMap - Opportunity New Map
     */
    public static void populateProductsSummary(Map<Id, Opportunity> oppNewMap){
        
        List<Opportunity> opplst = new List<Opportunity>();

        Set<Id> setOppIds = new Set<Id>();
        Set<Id> pricebookIds = new Set<Id>();
        
        for(Opportunity oppForVar : oppNewMap.Values()){
            if(oppForVar.PriceBook2Id != null
                && oppForVar.HasOpportunityLineItem) {
                setOppIds.add(oppForVar.Id);
                pricebookIds.add(oppForVar.PriceBook2Id);
            }
        }
            
        Map<Id,List<String>> strMap = new Map<Id,List<String>>();
        Map<String, Set<String>> pricebookToExcludeProMap = new Map<String, Set<String>>();
        Map<Id, PriceBook2> pricebook2Map = new Map<Id, PriceBook2>([SELECT Id, Name, CXT_Festival__r.Name FROM PriceBook2 WHERE ID IN: pricebookIds]);
        
        //Query Custom Metadata
        for(Opp_Product_Summary_Exclusion_List__mdt proExclusionList : [SELECT 
                                                          Pricebook_Name__c, Product_Name_To_Exclude__c
                                                        FROM Opp_Product_Summary_Exclusion_List__mdt
                                                        WHERE Is_Active__c = true]) {

            if(!pricebookToExcludeProMap.containsKey(proExclusionList.Pricebook_Name__c)) {
                pricebookToExcludeProMap.put(proExclusionList.Pricebook_Name__c, new Set<String> { });
                pricebookToExcludeProMap.get(proExclusionList.Pricebook_Name__c).addAll(proExclusionList.Product_Name_To_Exclude__c.split(';'));
            }   
        }
        
        if(!setOppIds.isEmpty()) {
            Map<Id, List<OpportunityLineItem>> oliByOpportunityIdMap = getOLIByOppId(setOppIds);
        
            for(Id oppId : setOppIds) {
                if(oliByOpportunityIdMap.get(oppId) != null) {
                    for(OpportunityLineItem oli : oliByOpportunityIdMap.get(oppId)) {

                        if(pricebook2Map.get(oppNewMap.get(oli.OpportunityId).PriceBook2Id) != null 
                            && (oli.Modifier_Type__c != 'Upgrade' || (oli.Modifier_Type__c == 'Upgrade' && oppNewMap.get(oli.OpportunityId).StageName == 'Closed Won'))) {
                            //Check with Exclusion List - If Product Name  contains in the metadata, then do not add it to the Product Summary
                            if(oppNewMap.get(oli.OpportunityId) != null
                                && pricebook2Map.get(oppNewMap.get(oli.OpportunityId).PriceBook2Id) != null
                                && pricebookToExcludeProMap.get(pricebook2Map.get(oppNewMap.get(oli.OpportunityId).PriceBook2Id).Name) != null 
                                && !pricebookToExcludeProMap.get(pricebook2Map.get(oppNewMap.get(oli.OpportunityId).PriceBook2Id).Name).contains(oli.Product2.Name)) {
                                if(strMap.containsKey(oli.OpportunityId)) {
                                    strMap.get(oli.OpportunityId).add((String.valueOf(oli.quantity)).substringBefore('.')+ ' x ' +oli.Product2.Name);
                                }
                                else {
                                    strMap.put(oli.OpportunityId, new List<String>{(String.valueOf(oli.quantity)).substringBefore('.')+ ' x ' +oli.Product2.Name});
                                }
                            }  
                        }
                    }
                }
            }    

            for(Opportunity oppVar :oppNewMap.Values()){
                string proName = '';
                if(strMap.containsKey(oppVar.Id)){
                    for(String str :strMap.get(oppVar.Id)) {
                        if(proName == '') {
                           proName = str+ ',';
                        }
                        else {
                             proName = proName + str + ',';
                        }    
                    }      
                    oppVar.Products_Summary__c = proName.removeEnd(',');
                }
                else {
                    oppVar.Products_Summary__c = '';
                }
                //Populate Festival name
                if(oppVar.Pricebook2Id != null && pricebook2Map.containsKey(oppVar.Pricebook2Id)){
                    oppVar.Festival_Name__c = pricebook2Map.get(oppVar.Pricebook2Id).CXT_Festival__r.Name;
                }
            } 
        }
    }

     /**
     * [updateRelatedPassRegistration Update Related Pass Reg to update Group Setting and Allotment field]
     * @param newMap [map with New values]
     * @param oldMap [Map with Old values]
     */
    public static void updateRelatedPassRegistration(Map<Id,Opportunity> oldMap, Map<Id,Opportunity> newMap) {

        Set<Id> oppIds = new set<Id>();
        Set<Id> alertNoteChangeOppIds = new Set<Id>();
        Set<Id> adminChargeOppIds = new Set<Id>();

        opportunityPassRegistrationMap = new Map<Id, List<CXT_Pass_Registration__c>>();

        List<CXT_Pass_Registration__c> passRegistrationList = new List<CXT_Pass_Registration__c>();
        List<CXT_Pass_Registration__c> passRegistrationListToUpdate = new List<CXT_Pass_Registration__c>();
        Set<CXT_Pass_Registration__c> passRegSet = new Set<CXT_Pass_Registration__c>();

        for(Opportunity oppVar : newMap.Values()) {
            //Updated related pass registration on these changes
            if((oppVar.Group_Settings__c != null 
                && oppVar.Group_Settings__c != oldMap.get(oppVar.Id).Group_Settings__c) || 
                (oppVar.Allotment__c != null 
                    && oppVar.Allotment__c != oldMap.get(oppVar.Id).Allotment__c) ||
                (oppVar.StageName == 'Closed Won' 
                    && oppVar.From_Basket_Reg__c 
                    && oldMap.get(oppVar.Id).StageName != oppVar.StageName)) {
                    
                    oppIds.add(oppVar.Id);
            }

            if(oppVar.Alert_Notes_for_Onsite__c != null 
                    && oppVar.Alert_Notes_for_Onsite__c != oldMap.get(oppVar.Id).Alert_Notes_for_Onsite__c) {
                alertNoteChangeOppIds.add(oppVar.Id);
            }
        } 
        oppIds.addAll(alertNoteChangeOppIds);

        if(!oppIds.isEmpty()) {
            opportunityPassRegistrationMap = getOpportunityPassRegistration(oppIds);
        }
        
        //Admin Charge Opportunity
        for(Opportunity oppVar : newMap.Values()) {

            if(opportunityPassRegistrationMap.get(oppVar.Id) != null) {
                passRegistrationList.addAll(opportunityPassRegistrationMap.get(oppVar.Id));
            }

            if(opportunityPassRegistrationMap.KeySet().contains(oppVar.Id)) {
                for(CXT_Pass_Registration__c thisPassRegistration : opportunityPassRegistrationMap.get(oppVar.Id)) {
                    if(thisPassRegistration.Opportunity_Admin_Charge__c != null){
                        adminChargeOppIds.add(thisPassRegistration.Opportunity_Admin_Charge__c);
                    }

                    if(alertNoteChangeOppIds.contains(thisPassRegistration.CXT_Opportunity_Name__c)) {
                        if(thisPassRegistration.Alert_Notes_for_Onsite__c != null) {
                            thisPassRegistration.Alert_Notes_for_Onsite__c = thisPassRegistration.Alert_Notes_for_Onsite__c +' '+oppVar.Alert_Notes_for_Onsite__c;
                        }
                    }
                }
            }
        }

        for(Id oppId : adminChargeOppIds) {
            if(opportunityPassRegistrationMap.get(oppId) != null) {
                for(CXT_Pass_Registration__c thisPassRegistration : opportunityPassRegistrationMap.get(oppId)) {
                    thisPassRegistration.CXT_Registration_Status__c = 'Processed';
                    passRegistrationList.add(thisPassRegistration);

                    if(thisPassRegistration.CXT_Previous_Pass_Registration__c != null){
                    
                        CXT_Pass_Registration__c pass1 = new CXT_Pass_Registration__c();
                        pass1.Id = thisPassRegistration.CXT_Previous_Pass_Registration__c;
                        pass1.CXT_Registration_Status__c = 'Void';
                        passRegistrationList.add(pass1);
                    }
                }
            }
        }

        passRegSet.addAll(passRegistrationList);
        passRegistrationListToUpdate.addAll(passRegSet);
        Update passRegistrationListToUpdate;
        
        /* UpdatePassRegistrationQueueable updatePassRegQ = new UpdatePassRegistrationQueueable(passRegistrationList, oldMap, newMap);
        System.enqueueJob(updatePassRegQ); */
    }

    /**
     * RA, 02/09/2017 - adjust the OLIs for the free sponsorship delegate passes
     */
    public static void adjustOLIsForFreePasses(Set<Id> oppIds) {
        
        String query = 'SELECT ' + util.getQueryStringForSObject('opportunity') + ', (SELECT PricebookEntry.Custom_Price__c, Product2.CXT_Product_Category__c, ' +
            util.getQueryStringForSObject('OpportunityLineItem') + 
            ' FROM OpportunityLineItems) FROM Opportunity WHERE id In : oppIds'; 

        List<Opportunity> oppList = Database.query(query); 

        // map holding the list of olis per opp per festival
        Map<Id, Map<Id, List<OpportunityLineItem>>> mapOppFest = new  Map<Id,Map<Id,List<OpportunityLineItem>>>();

        // Map holding the amount per festival per opp that should be deducted.
        Map<Id, Map<Id, decimal>> oppFestAmount = new Map<Id, Map<Id, decimal>>();

        for(Opportunity opp: oppList) {
            
            // get the map of the Festivals related to this opp
            Map<Id, List<OpportunityLineItem>> mapFest = mapOppFest.get(opp.id);
            
            // initialize if none found for the opp
            if(mapFest == null) {
                mapFest = new Map<Id, List<OpportunityLineItem>>();
            }

            // get the map of the Festivals related to this opp
            Map<Id, decimal> mapFestAmount = oppFestAmount.get(opp.id);
            
            // initialize if none found for the opp
            if(mapFestAmount == null) {
                mapFestAmount = new Map<Id, decimal>();
            }

            // iterate through the items to organize the olis per fest for the opp
            for(OpportunityLineItem oli: opp.OpportunityLineItems){
                // only continue if the oli has a festival
                if(oli.CXT_Festival__c == null) continue;

                // if the category is SPONSORED_DELEGATES then collect the amount for the festival to be decreased
                // which is in Map 2 otherwise add the oli to map 1.
                if(oli.Product2.CXT_Product_Category__c == SPONSORED_DELEGATES) { // add amount to map 2
                    decimal festAmount = mapFestAmount.get(oli.CXT_Festival__c);

                    // initialize if none found
                    if(festAmount == null) {
                        festAmount = 0;
                    }
                    if(oli.PricebookEntry.Custom_Price__c != null) {
                        festAmount += (oli.quantity * oli.PricebookEntry.Custom_Price__c);
                    }
                    
                    // put back in map
                    mapFestAmount.put(oli.CXT_Festival__c, festAmount);
                }
                else { // add to map 1
                    // determine which festival should get the opp line item
                    List<OpportunityLineItem> olisForFestival = mapFest.get(oli.CXT_Festival__c);

                    // initialize if none found
                    if(olisForFestival == null) {
                        olisForFestival = new List<OpportunityLineItem>();
                    }
                    olisForFestival.add(oli);
                    
                    // put back in map
                    mapFest.put(oli.CXT_Festival__c, olisForFestival);
                }
            }
            // put back in opp map
            mapOppFest.put(opp.id, mapFest);

            // put back in opp map
            oppFestAmount.put(opp.id, mapFestAmount);

        } // end for -- organized map for festival for opp and collect the amount per festival as well.

        // Map holding weightage for each OLI
        Map<Id, Decimal> mapOLIWeightage = new Map<Id, Decimal>();
        for(Opportunity opp: oppList) {
            // get map of festival olis
            Map<Id, List<OpportunityLineItem>> oppFestLIs = mapOppFest.get(opp.id);

            for(OpportunityLineItem oli: opp.OpportunityLineItems){
                
                // don't consider the oli if festival is not present
                if(oli.CXT_Festival__c == null) continue;

                // get Festival records for related OLIs only
                if(oppFestLIs.get(oli.CXT_Festival__c) == null) continue;

                // ignore SPONSORED_DELEGATES for reduction
                if(oli.Product2.CXT_Product_Category__c == SPONSORED_DELEGATES) {
                    continue;
                }

                // get weightage of the oli for the related festival from the map
                decimal weightage = getWeightage(oppFestLIs.get(oli.CXT_Festival__c), oli);

                mapOLIWeightage.put(oli.id, weightage);
            }
        }

        // get olis to update
        List<OpportunityLineItem> olisForUpdate = new List<OpportunityLineItem>();

        // iterate again to deduct the amount as per weightage calculation
        for(Opportunity opp: oppList) {
            // get map of festival olis
            Map<Id, List<OpportunityLineItem>> oppFestLIs = mapOppFest.get(opp.id);

            // get map of Festival amount
            Map<Id, decimal> mapFestAmt = oppFestAmount.get(opp.id);

            for(OpportunityLineItem oli: opp.OpportunityLineItems){
                
                // don't consider the oli if festival is not present
                if(oli.CXT_Festival__c == null) continue;

                // get Festival records for related OLIs only
                if(oppFestLIs.get(oli.CXT_Festival__c) == null) continue;

                // ignore SPONSORED_DELEGATES for reduction
                if(oli.Product2.CXT_Product_Category__c == SPONSORED_DELEGATES) {
                    oli.unitprice = oli.PriceBookEntry.Custom_Price__c;
                    olisForUpdate.add(oli);
                    continue;
                }

                if(mapFestAmt.get(oli.CXT_Festival__c) == null) continue;

                // get weightage of the oli for the related festival from the map
                decimal weightage = mapOLIWeightage.get(oli.id);

                // get total amount to be reduced from Map 2
                decimal totalAmt = mapFestAmt.get(oli.CXT_Festival__c);

                // reduce the amount now
                System.debug('>>>Weightage: ' + weightage + ', totalAmt: ' + totalAmt + ', totalPrice: ' + oli.TotalPrice);
                oli.TotalPrice -= (weightage * totalAmt);

                olisForUpdate.add(oli);
            }
        }

        // update olis
        if(olisForUpdate.size() > 0) {
            System.debug('>>> OLIs for Update: ' + olisForUpdate);
            Database.SaveResult[] result = Database.update(olisForUpdate);
            ADJUSTED_WEIGHTAGE = true;
        }
    }

    /**
     * @description: calculate weightage of the line item
     * @params: 
     *      Map<Id, List<OpportunityLineItem>> map to inspect
     *      OpportunityLineItem: OLI for which weight is required
     */
    private static decimal getWeightage(List<OpportunityLineItem> olis, OpportunityLineItem oli) {
        decimal totalAmount = 0.0;

        for(OpportunityLineItem oliTemp: olis) {
            totalAmount += oliTemp.TotalPrice;
        }
        if(totalAmount<=0){
        totalAmount=1;
        return (oli.TotalPrice / totalAmount);
        }
        else{
        return (oli.TotalPrice / totalAmount);
        }
    }

    /**
     * createContactRoles Create Opportunity Contact Role On Create / Update Opportunity
     * @param  oppNewMap old values of sObject opportunities
     * @param  oppOldMap new values of sObject opportunities
     * @return           Contact Role List to Insert
     */
    public static List<OpportunityContactRole> createContactRoles(Map<Id, Opportunity> oppOldMap, Map<Id, Opportunity> oppNewMap) {

        List<OpportunityContactRole> conRoleList = new List<OpportunityContactRole>();
        Map<String,List<Opportunity_Contact_Role_Setting__mdt>> oppContactRoleMtdMap = new Map<String,List<Opportunity_Contact_Role_Setting__mdt>>();
        Map<Id,String> oppRecTypeMap = new Map<Id,String>();
        Map<Id, Set<Id>> oppIdToPrimaryContactRoleId = new Map<Id, Set<Id>>();
       
        for(Opportunity_Contact_Role_Setting__mdt ocr : [SELECT Contact_Lookup_Field_API_Name__c,
                                                                 Contact_Role__c,
                                                                 Is_Primary_Contact__c,
                                                                 Opportunity_Record_Type_API_Name__c
                                                                 FROM Opportunity_Contact_Role_Setting__mdt]){

            if(oppContactRoleMtdMap.containsKey(ocr.Opportunity_Record_Type_API_Name__c)) {
                oppContactRoleMtdMap.get(ocr.Opportunity_Record_Type_API_Name__c).add(ocr);
            }
            else {
                oppContactRoleMtdMap.put(ocr.Opportunity_Record_Type_API_Name__c, new List<Opportunity_Contact_Role_Setting__mdt> { ocr });
            }
        }

        for(String recTypeDevName : oppContactRoleMtdMap.keySet()){
            oppRecTypeMap.put(Util.getRecordTypeIdByDevName('Opportunity', recTypeDevName), recTypeDevName);
        }

        for(OpportunityContactRole oCR:[SELECT
                                          ContactID,
                                          OpportunityId
                                          FROM OpportunityContactRole
                                          WHERE OpportunityId IN: oppNewMap.KeySet()
                                          ]) {
                                        if(oppIdToPrimaryContactRoleId.containsKey(oCR.OpportunityId)) {
                                            oppIdToPrimaryContactRoleId.get(oCR.OpportunityId).add(oCR.ContactID);
                                        }
                                        else {
                                            oppIdToPrimaryContactRoleId.put(oCR.OpportunityId, new Set<Id> { oCR.ContactID });
                                        }
                                  }

        //Create Contact Roles
        for(Opportunity opp : oppNewMap.values()) {
            if(oppRecTypeMap.KeySet().contains(opp.RecordTypeId)) {
                for(Opportunity_Contact_Role_Setting__mdt oppMdt : oppContactRoleMtdMap.get(oppRecTypeMap.get(opp.RecordTypeId))) {

                    //Contact Look Up Is Blank, Move To Next Record
                    if(opp.get(oppMdt.Contact_Lookup_Field_API_Name__c) == null) continue;

                    if(oppIdToPrimaryContactRoleId.get(opp.Id) != null 
                        && oppIdToPrimaryContactRoleId.get(opp.Id).contains((ID)opp.get(oppMdt.Contact_Lookup_Field_API_Name__c))) continue; 

                    OpportunityContactRole newCR = new OpportunityContactRole();
                    newCR.ContactID              = (ID)opp.get(oppMdt.Contact_Lookup_Field_API_Name__c);
                    newCR.OpportunityId          = opp.Id;
                    newCR.IsPrimary              = oppMdt.Is_Primary_Contact__c;
                    newCR.Role                   = oppMdt.Contact_Role__c;
                    conRoleList.add(newCR);
                }
            }
        }
 
        return conRoleList;
    }


    public Static void createAssetOnOpportunityUpdate(Map<Id, Opportunity> oldOpportunity, Map<Id, Opportunity> newOpportunity, String createAssetStage){

        Map<String, Id> mapRecordType = new Map<String, Id>();
        Boolean isOnsiteOppAsset = false;
        List<RecordType> rt = [SELECt Id,Name FROM RecordType WHERE SobjectType=:CXT_Constants.SOBJECTTYPE_ASSET 
                                                                 OR SobjectType=:CXT_Constants.SOBJECTTYPE_PASS_REGISTRATION];

        for(RecordType r:rt){
            mapRecordType.put(r.Name, r.Id);
        }

        Set<Id> opportunityIds = new Set<Id>();
        Map<Id, Asset> assetToInsert = new Map<Id, Asset>();
        List<OpportunityLineItem> oliUpdate = new List<OpportunityLineItem>();

        for(Opportunity newOpp: newOpportunity.values()){
            //Invoke From After Update Trigger
            if(oldOpportunity != null && newOpp.IsWon && (newOpp.IsWon != oldOpportunity.get(newOpp.Id).IsWon)){
                opportunityIds.add(newOpp.Id);
            }

            //Invoke From Button On Opportunity Page To Create Asset / Pass Registration
            else if(Test.isRunningTest() || (newOpp.IsWon && createAssetStage == 'Manual')){
                 opportunityIds.add(newOpp.Id);
            }

            //Logic Will Be Fired From Batch Apex To Create Assets For Opportunities Created Onsite
            else if(oldOpportunity == null && createAssetStage == 'Closed Won'){
                isOnsiteOppAsset = true;
                opportunityIds.add(newOpp.Id);
            }
        }

        List<CXT_Pass_Registration__c> childpasses = new List<CXT_Pass_Registration__c>();
        Map<String,List<CXT_Pass_Registration__c>> mapAssetToNoOfPasses = new Map<String,List<CXT_Pass_Registration__c>>();
        List<OpportunityLineItem> lstOpportunityProduct = getOpportunityLineItem(opportunityIds, createAssetStage);

        for(OpportunityLineItem oli : lstOpportunityProduct){
            Asset ast = new Asset();
            if(mapRecordType.get(oli.Product2.CXT_Asset_Record_Type__c) != null)
                ast.RecordTypeId    = mapRecordType.get(oli.Product2.CXT_Asset_Record_Type__c);
                ast.AccountId       = oli.opportunity.AccountId;
                ast.CXT_Opportunity__c  = oli.OpportunityId;
                ast.Status              = CXT_Constants.ASSET_STATUS_IN_PROGRESS;
                ast.Product2Id  = oli.Product2Id;
                ast.Name        = Oli.Name;
                
                if(oli.Product2.CXT_No_of_Delegates__c != null)
                    ast.CXT_Total_No_Of_Delegates__c = oli.Product2.CXT_No_of_Delegates__c * oli.Quantity;
                
                if(oli.Product2.Family == CXT_Constants.PRODUCT_FAMILY)
                    ast.CXT_Total_No_of_Entries__c = oli.Quantity;
                
                ast.Group_Booking__c = oli.opportunity.CXT_Group_Booking__c;
                
                if(oli.CXT_Festival__c != null){
                    ast.CXT_Festival__c = oli.CXT_Festival__c;
                }
                
                else if(oli.PriceBookEntry.PriceBook2.CXT_Festival__c != null){
                    ast.CXT_Festival__c = oli.PriceBookEntry.PriceBook2.CXT_Festival__c;
                }
                if(oli.Product2.CXT_No_of_Subscribers__c != null)
                    ast.CXT_Total_No_of_Subscribers__c = oli.Product2.CXT_No_of_Subscribers__c * oli.Quantity;
                
                if(oli.Product2.No_of_Companion_Delegates__c != null)
                ast.CXT_Total_No_Of_Companion_Delegate__c = oli.Product2.No_of_Companion_Delegates__c * oli.Quantity;
                ast.CXT_Original_Booking_Contact__c = oli.Opportunity.CXT_Booking_Contact__c;
                ast.CXT_Original_Booking_Account__c = oli.Opportunity.CXT_Booking_Contact__r.AccountId;
                assetToInsert.put(Oli.Product2Id, ast);
        }

        if(!assetToInsert.isEmpty()){
           
            Insert assetToInsert.values();

            Map<String, List<CXT_Pass_Registration__c>> mapProductToPasses = new Map<String , List<CXT_Pass_Registration__c>>();                                                   
            for(CXT_Pass_Registration__c pass: [Select  Id, 
                    Name,
                    CXT_Asset__c, 
                    CXT_Opportunity_Name__c,
                    CXT_Product_Name__c,
                    CXT_Product_Name__r.CXT_Companion_Addon__c,
                    Type__c,
                    CXT_Master_Pass_Registration__c,
                    RecordTypeId,
                    CXT_Known_As__c from CXT_Pass_Registration__c where CXT_Opportunity_Name__c in :OpportunityIds and CXT_Product_Name__c!=null ]) {
            
                    List<CXT_Pass_Registration__c> lstPass = mapProductToPasses.get(pass.CXT_Opportunity_Name__c+''+ pass.CXT_Product_Name__c);
                    if(lstPass == null) lstPass = new List<CXT_Pass_Registration__c>();
                    lstPass.add(pass);
                    mapProductToPasses.put(pass.CXT_Opportunity_Name__c+''+pass.CXT_Product_Name__c, lstPass);
                } 

            List<CXT_Pass_Registration__c> lstInsertPass = new List<CXT_Pass_Registration__c>();
            List<CXT_Pass_Registration__c> lstInsert = new List<CXT_Pass_Registration__c>();
            

            for(Asset asst :  assetToInsert.values()){
               Integer required = Integer.ValueOf(asst.CXT_Total_No_Of_Delegates__c);
                lstInsert = mapProductToPasses.get(String.ValueOf(asst.CXT_Opportunity__c)+ String.ValueOf(asst.Product2Id));
                if(lstInsert == null ) lstInsert = new List<CXT_Pass_Registration__c>();
                if(required != null){       
                    Integer existing = lstInsert.size();
                    system.debug('existing '+existing+' required '+required);
                    Integer diff = required - existing;
                    // current passes in db are >= required
                    
                    if(diff < 0) {
                       // update only upto required passes
                        for(integer ctr=0; ctr < required; ctr++) {
                            CXT_Pass_Registration__c cpassr = lstInsert[ctr];
                            cpassr.CXT_Asset__c = asst.Id;
                            cpassr.CXT_Festival__c = asst.CXT_Festival__c;
                            lstInsertPass.add(cpassr);
                        }
                    }
                    else {
                        for(integer ctr=0; ctr < existing; ctr++) {
                            CXT_Pass_Registration__c cpassr = lstInsert[ctr];
                            cpassr.CXT_Asset__c = asst.Id;
                            cpassr.CXT_Festival__c = asst.CXT_Festival__c;
                            lstInsertPass.add(cpassr);
                        }
                        for(integer ctr=0; ctr < diff; ctr++) {
                            Id passRegRecordTypeId = Util.getRecordTypeIdByDevName('CXT_Pass_Registration__c',PASS_DELEGATE_REGISTRATION); 
                            CXT_Pass_Registration__c pass = (CXT_Pass_Registration__c)CXT_Pass_Registration__c.sObjectType.newSObject(passRegRecordTypeId, true);
                            pass.RecordTypeId = passRegRecordTypeId;
                            pass.CXT_Asset__c = asst.Id;
                            pass.CXT_Product_Name__c = asst.Product2Id;
                            pass.CXT_Opportunity_Name__c = asst.CXT_Opportunity__c;
                            pass.CXT_Festival__c = asst.CXT_Festival__c;
                            pass.CXT_Original_Booking_Contact__c = asst.CXT_Original_Booking_Contact__c;
                            lstInsertPass.add(pass);
                        }
                    }
                }

            }
            if(lstInsertPass.size() > 0){
                //Turn Off Trigger
                if(isOnsiteOppAsset) {
                     PassRegistrationTriggerHandler.runOnce = false;
                }
                upsert lstInsertPass;
            }
            /**
            * Create child pass where Product2.Campanion_Add_on is applicable
            **/
            for(CXT_Pass_Registration__c cpass : [Select Id,CXT_Product_Name__r.CXT_Companion_Addon__c,CXT_Asset__c,Name,
                                                    CXT_Product_Name__c from CXT_Pass_Registration__c 
                                                    where CXT_Opportunity_Name__c In : OpportunityIds and CXT_Asset__c != null and CXT_Product_Name__r.CXT_Companion_Addon__c=:true]){
                CXT_Pass_Registration__c pass= new CXT_Pass_Registration__c();
                pass.CXT_Master_Pass_Registration__c = cpass.Id;
                pass.CXT_Product_Name__c = cpass.CXT_Product_Name__c;
                pass.RecordTypeId = mapRecordType.get(CXT_Constants.PASS_COMPANION_ENTOURAGE);
                pass.Type__c = CXT_Constants.PASS_ENTOURAGE;
                pass.Name = cpass.Name;
                pass.CXT_Known_As__c = CXT_Constants.PASS_ENTOURAGE;
                pass.CXT_Asset__c = cpass.CXT_Asset__c;
                childpasses.add(pass);
            }

            if(childpasses.size() > 0){ 
                //Turn Off Trigger
                if(isOnsiteOppAsset) {
                     PassRegistrationTriggerHandler.runOnce = false;
                }
               
                Insert childpasses;
            }
            
            //Associate Entry records with Asset
            List<CXT_Entry__c> lstEntry = [Select Id, CXT_Asset__c, CXT_Product2__c, CXT_Opportunity__c from CXT_Entry__c  
                                            where CXT_Opportunity__c IN:OpportunityIds and CXT_Product2__c !=null];
            for(CXT_Entry__c entry :lstEntry){
                if(assetToInsert.containsKey(entry.CXT_Product2__c) && 
                    assetToInsert.get(entry.CXT_Product2__c).CXT_Opportunity__c == entry.CXT_Opportunity__c){
                    entry.CXT_Asset__c = assetToInsert.get(entry.CXT_Product2__c).Id;
                }
            }

            if(lstEntry.size() > 0){
                upsert lstEntry;
            }       
        }

        //Update Opportunity Line Item with Assets
        if(assetToInsert.values().size() > 0){
            for(OpportunityLineItem oli: lstOpportunityProduct){
                OpportunityLineItem ol = new OpportunityLineItem();
                ol.Id = oli.Id;
                if(assetToInsert.get(oli.Product2Id) != null)
                    ol.CXT_Asset__c = assetToInsert.get(oli.Product2Id).Id;
                OliUpdate.add(ol);
            }
            if(OliUpdate.size() > 0){
                update OliUpdate;
            }
        }
    }

    /**
    *   Get all Opportunity Products from Opportunity Ids
    **/
    public static List<OpportunityLineItem> getOpportunityLineItem(Set<Id> oppoIds, String createAssetStage){

        List<OpportunityLineItem>  lstOpportunityProduct = new List<OpportunityLineItem>();
        String oliQuery;
      
        oliQuery = 'SELECT Id, Name, Opportunityid, opportunity.AccountId, CXT_Festival__c, CXT_Asset__c, CXT_Asset_Required__c, CXT_Asset__r.CXT_Opportunity__c, Quantity, Opportunity.Name,'+
                    'Opportunity.Stagename, Opportunity.IsWon, Opportunity.Type, Opportunity.CXT_Group_Booking__c, Opportunity.CXT_Booking_Contact__c, Opportunity.CXT_Booking_Contact__r.AccountId,'+
                    'Product2Id,PriceBookEntry.CXT_Festival__c, PriceBookEntry.PriceBook2.CXT_Festival__c, Product2.Family, Product2.Name, Product2.CXT_Asset_Record_Type__c, Product2.CXT_No_of_Delegates__c,'+
                    'Product2.CXT_No_of_Subscribers__c, Product2.CXT_Companion_Addon__c,Product2.No_of_Companion_Delegates__c, Product2.Create_Asset__c '+
                    'FROM OpportunityLineItem WHERE CXT_Asset_Required__c = true AND Product2.CXT_Asset_Record_Type__c != null AND Opportunityid IN :oppoIds AND CXT_Asset__c = null';


        if(createAssetStage == 'Closed Won') {
            oliQuery = oliQuery + ' AND (Product2.Create_Asset__c =: createAssetStage OR Product2.Create_Asset__c = null)';
        }
        else{ 
            oliQuery = oliQuery + ' AND Product2.Create_Asset__c =: createAssetStage';
        }
                                
        lstOpportunityProduct = Database.query(oliQuery);
        return lstOpportunityProduct;
    }

    /**
     * Collect all pass registrations related to Opportunity
     * a. Populate Paid Passes That Needs Email Sent - Rollup Paid / Processed Passes in Opportunity
     * b. Update Pass Registrations when Allotment, Group Settings Is Changed or Admin Charge Pass Registration Status For Admin Charge Opportunities
     */
    private static Map<Id, List<CXT_Pass_Registration__c>> getOpportunityPassRegistration(Set<Id> oppIds) {

        if(opportunityPassRegistrationMap.isEmpty() && !oppIds.isEmpty()) {
        
            for(CXT_Pass_Registration__c thisPassRegistration : [SELECT Id,
                                                    Name,
                                                    CXT_Asset__c, 
                                                    CXT_Opportunity_Name__c,
                                                    CXT_Product_Name__c,
                                                    CXT_Product_Name__r.CXT_Companion_Addon__c,
                                                    Type__c,
                                                    CXT_Master_Pass_Registration__c,
                                                    RecordTypeId,
                                                    CXT_Known_As__c,
                                                    Opportunity_Admin_Charge__c,
                                                    CXT_Payment_Status_2__c,
                                                    CXT_Registration_Status__c,
                                                    CXT_Product_Name__r.Name,
                                                    CXT_Previous_Pass_Registration__c,
                                                    Alert_Notes_for_Onsite__c
                                                FROM CXT_Pass_Registration__c 
                                                WHERE CXT_Opportunity_Name__c IN: oppIds
                                                    OR Opportunity_Admin_Charge__c IN: oppIds]) {

                if(opportunityPassRegistrationMap.containsKey(thisPassRegistration.CXT_Opportunity_Name__c)) {
                    opportunityPassRegistrationMap.get(thisPassRegistration.CXT_Opportunity_Name__c).add(thisPassRegistration);
                }
                else {
                    opportunityPassRegistrationMap.put(thisPassRegistration.CXT_Opportunity_Name__c, new List<CXT_Pass_Registration__c> { thisPassRegistration });
                }
            }
        }
        return opportunityPassRegistrationMap;
    }

    private static Map<Id, List<OpportunityLineItem>> getOLIByOppId(Set<Id> oppIds) {

        if(oliByOppIdMap.isEmpty() && !oppIds.isEmpty()) {
             String query = 'SELECT Product2.Name, PricebookEntry.Custom_Price__c, Product2.CXT_Product_Category__c, ' +util.getQueryStringForSObject('OpportunityLineItem') + 
                ' FROM OpportunityLineItem WHERE OpportunityId In : oppIds'; 

            for(OpportunityLineItem thisoli : Database.query(query)) {
                if(oliByOppIdMap.containsKey(thisoli.OpportunityId)) {
                    oliByOppIdMap.get(thisoli.OpportunityId).add(thisoli);
                }
                else {
                    oliByOppIdMap.put(thisoli.OpportunityId, new List<OpportunityLineItem> { thisoli });
                }
            }
        }
        return oliByOppIdMap;
    }
    
    public static Attachment createAttachment(Staticresource staticRes,Id oppId){
        attachment attach = new attachment();
        attach.body = staticRes.body;
        attach.name = staticRes.name+'.doc';
        attach.ContentType = staticRes.ContentType;
        attach.parentid = oppId;
        return attach;
    }
    public static void attachSPONContractToOpp(List<Opportunity> oppList){
        staticresource staticr = [SELECT Id,name, body, ContentType FROM staticresource WHERE name = 'Lions_Sponsorship_Contract'];

        List<attachment> attachmentsToAdd = new List<Attachment>();
        Set<ID> RTIds = new Set<ID>();  //set of Record Type IDs to match
        
        RecordType RT = [SELECT id FROM Recordtype WHERE Name = 'Sponsorship'];
        RTids.add(rt.id);
        
        for(Opportunity opp : oppList){
            if(RTIds.contains(opp.Recordtypeid)){
                attachment attachment = new attachment();
                attachment.body = staticr.body;
                attachment.name = staticr.name+'.doc';
                attachment.ContentType = staticr.ContentType;
                attachment.parentid = opp.id;
                system.debug(attachment);
                attachmentsToAdd.add(attachment);
            }
        }
        system.debug(attachmentsToAdd);
        insert attachmentsToAdd;    
    }
    
    public static void attachEurobestContractToOpp(List<Opportunity> oppList){
         //get static resource for Eurobest festival
         staticresource staticrEurobest = [SELECT id,name, body, ContentType FROM staticresource WHERE name = 'Lions_Eurobest_Contract'];

         //List to add attachments
         List<attachment> attachmentsToAdd = new List<Attachment>();
         //Get id of sponsorship recordtype,attachment will be added for Sponsorship opps only
         String SponsorshipOpportunityRTId = 
         Schema.SObjectType.Opportunity.getRecordTypeInfosByName().get('Sponsorship').getRecordTypeId();
         //Set of Opportunity ids who already have Eurobest Attachment(Avoiding multiple attachments)
         Set<Id> oppIds = new Set<Id>();
         //Get existing Eurobest attachment
         Map<Id,Attachment> mapOpportunityAttachmet = new Map<Id,Attachment>();
         List<Attachment> findAttach = [Select id,parentId from Attachment where parentId In : Trigger.new and name = : 'Lions_Eurobest_Contract.doc'];
         for(Attachment attach : findAttach){
             if(!mapOpportunityAttachmet.containsKey(attach.parentId)){
                 mapOpportunityAttachmet.put(attach.parentId,attach);
             }
         }
         for(Opportunity opp : oppList){
             //Opportunity must be of Sponsorship rectype and should not have existing Eurobest contract
             if(opp.RecordTypeId == SponsorshipOpportunityRTId && !mapOpportunityAttachmet.containsKey(opp.Id)){
                 //Check if Eurobest passes is not 0(Opp is Eurobest)
                 if(opp.Eurobest_passes__c != 0){
                     //For Eurobest festival
                     attachmentsToAdd.add(createAttachment(staticrEurobest,opp.Id));
                     oppIds.add(opp.Id);
                 }
             }
         }
         //Delete existing cannes contract if any.
         if(oppIds.size()>0){
             List<Attachment> lstAttachment = [Select Id from Attachment where parentId In : oppIds and name =: 'Lions_Sponsorship_Contract.doc'];
             if(lstAttachment != null && lstAttachment.size()>0){
                 delete lstAttachment;
             }
         }
         //Add attachmet on opportunity.
         if(attachmentsToAdd.size()>0){
             insert attachmentsToAdd;
         }
    }
}