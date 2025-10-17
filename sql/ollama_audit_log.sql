--------------------------------------------------------
--  File created - Friday-October-17-2025   
--------------------------------------------------------
--------------------------------------------------------
--  DDL for Table OLLAMA_AUDIT_LOG
--------------------------------------------------------

create table "OLLAMA_AUDIT_LOG" (
   "AUDIT_ID"         number primary key,
   "CREATED_AT"       timestamp(6) with time zone default systimestamp,
   "REQUESTOR"        varchar2(200 byte) collate "USING_NLS_COMP",
   "TABLE_NAME"       varchar2(128 byte) collate "USING_NLS_COMP",
   "MODEL"            varchar2(200 byte) collate "USING_NLS_COMP",
   "USER_PROMPT"      clob collate "USING_NLS_COMP",
   "REQUEST_BODY"     clob collate "USING_NLS_COMP",
   "RESPONSE_JSON"    clob collate "USING_NLS_COMP",
   "GENERATED_SQL"    clob collate "USING_NLS_COMP",
   "EXECUTION_RESULT" clob collate "USING_NLS_COMP",
   "STATUS"           varchar2(50 byte) collate "USING_NLS_COMP",
   "ERROR_MESSAGE"    clob collate "USING_NLS_COMP"
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
