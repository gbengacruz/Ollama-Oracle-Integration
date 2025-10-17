--------------------------------------------------------
--  File created - Friday-October-17-2025   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table OLLAMA_AUDIT_LOG
--------------------------------------------------------

  CREATE TABLE "OLLAMA_AUDIT_LOG" 
   (	"AUDIT_ID" NUMBER, 
	"CREATED_AT" TIMESTAMP (6) WITH TIME ZONE DEFAULT SYSTIMESTAMP, 
	"REQUESTOR" VARCHAR2(200 BYTE) COLLATE "USING_NLS_COMP", 
	"TABLE_NAME" VARCHAR2(128 BYTE) COLLATE "USING_NLS_COMP", 
	"MODEL" VARCHAR2(200 BYTE) COLLATE "USING_NLS_COMP", 
	"USER_PROMPT" CLOB COLLATE "USING_NLS_COMP", 
	"REQUEST_BODY" CLOB COLLATE "USING_NLS_COMP", 
	"RESPONSE_JSON" CLOB COLLATE "USING_NLS_COMP", 
	"GENERATED_SQL" CLOB COLLATE "USING_NLS_COMP", 
	"EXECUTION_RESULT" CLOB COLLATE "USING_NLS_COMP", 
	"STATUS" VARCHAR2(50 BYTE) COLLATE "USING_NLS_COMP", 
	"ERROR_MESSAGE" CLOB COLLATE "USING_NLS_COMP"
   ) ;
--------------------------------------------------------
--  DDL for Trigger OLLAMA_AUDIT_LOG_TRG
--------------------------------------------------------

  CREATE OR REPLACE  TRIGGER "OLLAMA_AUDIT_LOG_TRG" BEFORE INSERT OR UPDATE ON "OLLAMA_AUDIT_LOG" 
   FOR EACH ROW 
 BEGIN 

	if :new.audit_id is null then
	   :new.audit_id := ollama_audit_seq.nextval;
    end if;

    IF inserting then
        :new.CREATED_AT := localtimestamp;
        :new.REQUESTOR := (nvl(sys_context('APEX$SESSION','APP_USER'),user));
    END IF;

 END OLLAMA_AUDIT_LOG_TRG;
/
ALTER TRIGGER "OLLAMA_AUDIT_LOG_TRG" ENABLE;
--------------------------------------------------------
--  Constraints for Table OLLAMA_AUDIT_LOG
--------------------------------------------------------

  ALTER TABLE "OLLAMA_AUDIT_LOG" ADD PRIMARY KEY ("AUDIT_ID") ENABLE;
  
/

CREATE SEQUENCE  "OLLAMA_AUDIT_SEQ"  MINVALUE 1 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 43 NOCACHE  NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL ;
/
