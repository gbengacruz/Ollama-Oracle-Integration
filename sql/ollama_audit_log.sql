--------------------------------------------------------
--  File created - Friday-October-17-2025   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table OLLAMA_AUDIT_LOG
--------------------------------------------------------

create table "OLLAMA_AUDIT_LOG" (
   "AUDIT_ID"         number primary key,
   "CREATED_AT"       timestamp(6) ,
   "REQUESTOR"        varchar2(200 byte),
   "TABLE_NAME"       varchar2(128 byte),
   "MODEL"            varchar2(200 byte),
   "USER_PROMPT"      clob,
   "REQUEST_BODY"     clob, 
   "RESPONSE_JSON"    clob,
   "GENERATED_SQL"    clob,
   "EXECUTION_RESULT" clob,
   "STATUS"           varchar2(50 byte),
   "ERROR_MESSAGE"    clob
);

--------------------------------------------------------
--  DDL for Trigger OLLAMA_AUDIT_LOG_TRG
--------------------------------------------------------
create sequence "OLLAMA_AUDIT_SEQ" minvalue 1 maxvalue 9999999999999999999999999999 increment by 1 start with 1;


create or replace trigger "OLLAMA_AUDIT_LOG_TRG" before
   insert or update on "OLLAMA_AUDIT_LOG"
   for each row
begin
   if :new.audit_id is null then
      :new.audit_id := ollama_audit_seq.nextval;
   end if;

   if inserting then
      :new.created_at := localtimestamp;
      :new.requestor := ( nvl(
         sys_context(
            'APEX$SESSION',
            'APP_USER'
         ),
         user
      ) );
   end if;

end ollama_audit_log_trg;
/
