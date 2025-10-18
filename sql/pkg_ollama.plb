create or replace PACKAGE BODY pkg_ollama AS

    -- Constants for configuration
    gc_ollama_endpoint CONSTANT VARCHAR2(500) := 'http://localhost:11434/api/generate';
    gc_ollama_api_key  CONSTANT VARCHAR2(100) := 'skLocal_1a2b3c4d5e6f7xxxxxxxxxxxxxxx';
    gc_default_model   CONSTANT VARCHAR2(100) := 'llama3.1:8b';
    gc_success_status  CONSTANT VARCHAR2(100) := 'Succeeded';
    gc_fail_status     CONSTANT VARCHAR2(100) := 'Failed';


    --audit log
    PROCEDURE ollama_audit_log_prc (
        p_table_name       VARCHAR2 DEFAULT NULL,
        p_model            VARCHAR2 DEFAULT NULL,
        p_user_prompt      CLOB DEFAULT NULL,
        p_request_body     CLOB DEFAULT NULL,
        p_response_json    CLOB DEFAULT NULL,
        p_generated_sql    CLOB DEFAULT NULL,
        p_execution_result CLOB DEFAULT NULL,
        p_status           VARCHAR2 DEFAULT NULL,
        p_error_message    CLOB DEFAULT NULL
    ) IS
    BEGIN
        INSERT INTO ollama_audit_log (
            table_name,
            model,
            user_prompt,
            request_body,
            response_json,
            generated_sql,
            execution_result,
            status,
            error_message
        ) VALUES (
            p_table_name,
            p_model,
            p_user_prompt,
            p_request_body,
            p_response_json,
            p_generated_sql,
            p_execution_result,
            p_status,
            p_error_message
        );

        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE;
    END ollama_audit_log_prc;

    /*
    * FUNCTION: query_to_json_array
    * Converts any SELECT query results to JSON array format
    */
    FUNCTION query_to_json_array (
        p_query IN CLOB
    ) RETURN NCLOB IS
        l_validation VARCHAR2(4000);
        l_sql        CLOB;
        l_json       CLOB;
        l_out        NCLOB;
    BEGIN
        IF p_query IS NULL OR trim(p_query) = '' THEN
            raise_application_error(-20020, 'query is required');
        END IF;

        -- MANDATORY: Validate before any dynamic SQL
        l_sql := replace(trim(p_query), ';', '');
        l_validation := validate_sql_syntax(l_sql);
        IF l_validation != 'VALID' THEN
            RETURN to_nclob('{"error":"Invalid query"}');
        END IF;

     -- Build JSON aggregation SQL
        l_sql := 'SELECT COALESCE('
                 || '  JSON_ARRAYAGG(JSON_OBJECT(*) RETURNING CLOB),'
                 || '  TO_CLOB(''[]'')'
                 || ') AS j FROM ('
                 || l_sql
                 || ') q';

        -- Execute and fetch as CLOB
        EXECUTE IMMEDIATE l_sql
        INTO l_json;
         -- Convert explicitly to NCLOB before returning
        l_out := to_nclob(l_json);
        RETURN l_out;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN to_nclob('{"error":"'
                            || replace(sqlerrm, '"', '\"')
                            || '"}');
    END query_to_json_array;


    /*
    * FUNCTION: generate_sql_from_ollama
    * Generates Oracle SQL from natural language prompts using Ollama AI
    */
    FUNCTION generate_sql_from_ollama (
        p_table_name  IN VARCHAR2 DEFAULT NULL,
        p_user_prompt IN VARCHAR2
    ) RETURN CLOB AS

        l_metadata_json CLOB;
        l_payload       CLOB;
        l_response      CLOB;
        l_sql           CLOB;
        l_bad_tokens    VARCHAR2(4000);
        l_system_prompt CLOB;
        l_validation    VARCHAR2(4000);
    BEGIN
        -- Build schema metadata if table provided
        IF p_table_name IS NOT NULL THEN
            SELECT
                JSON_ARRAYAGG(
                    JSON_OBJECT(
                        'column_name' VALUE column_name,
                        'data_type' VALUE data_type,
                        'data_length' VALUE data_length
                    )
                RETURNING CLOB)
            INTO l_metadata_json
            FROM
                all_tab_columns
            WHERE
                    instr(':'
                          || p_table_name
                          || ':', ':'
                                  || table_name
                                  || ':') > 0 --Allow multiple with ":" separation
                AND owner = sys_context('USERENV', 'CURRENT_SCHEMA');

        ELSE
            l_metadata_json := '[]';
        END IF;

        -- Strong system prompt: force Oracle SQL dialect only
        l_system_prompt := 'You are an expert Oracle SQL generator. STRICT RULES:'
                           || chr(10)
                           || '- Return ONLY valid Oracle SQL statements (compatible with Oracle 19c/21c). No explanations, no comments, no surrounding text, no markdown, no code fences (```).'
                           || chr(10)
                           || '- Use Oracle idioms where appropriate (FROM DUAL for constant selects, NVL, TO_DATE, TO_CHAR, ROWNUM or FETCH FIRST ... ROWS ONLY for limiting). Do NOT use LIMIT, backticks (`), TOP, ILIKE, SERIAL, or Postgres/MySQL-specific functions.'
                           || chr(10)
                           || '- Use standard Oracle functions and datatypes. Do NOT invent vendor-specific syntax from other databases.'
                           || chr(10)
                           || '- If you cannot produce valid Oracle SQL, respond with exactly: ERROR_NON_ORACLE_SQL'
                           || chr(10)
                           || '- Return only the SQL; nothing else.';

        -- Build JSON payload safely using APEX_JSON
        apex_json.initialize_clob_output;
        apex_json.open_object;

        -- Model selection
        apex_json.write('model', gc_default_model);

        -- Provide the system message separately (Ollama supports `system` parameter)
        apex_json.write('system', l_system_prompt);

        -- Build the prompt that includes the user's request and optional schema
        apex_json.write('prompt', 'User prompt: '
                                  || chr(10)
                                  || p_user_prompt
                                  ||
            CASE
                WHEN p_table_name IS NOT NULL THEN
                    chr(10)
                    || chr(10)
                    || 'Schema metadata (JSON):'
                    || chr(10)
                    || l_metadata_json
                ELSE ''
            END
                                  || chr(10)
                                  || chr(10)
                                  || 'IMPORTANT: Output must be a single SQL statement or a set of SQL statements separated by semicolons, each valid Oracle SQL. No markdown, no explanations.'
                                  );

        -- Deterministic options: temperature 0 to reduce hallucinations / dialect drift
        apex_json.open_object('options');
        apex_json.write('temperature', 0);
        apex_json.close_object;

        -- Disable streaming so we get the full response in one object
        apex_json.write('stream', FALSE);
        apex_json.close_object;
        l_payload := apex_json.get_clob_output;
        apex_json.free_output;

        apex_web_service.set_request_headers(
            p_name_01        => 'Content-Type',
            p_value_01       => 'application/json',
            p_name_02        => 'User-Agent',
            p_value_02       => 'APEX',
            p_name_03        => 'X-API-Key',
            p_value_03       => gc_ollama_api_key);

        -- Call Ollama REST API
        l_response := apex_web_service.make_rest_request(p_url => gc_ollama_endpoint, p_http_method => 'POST', p_body => l_payload,p_parm_name => apex_util.string_to_table
        ('Content-Type'), p_parm_value => apex_util.string_to_table('application/json'));

        -- Extract model response (final non-streamed response lives in $.response)
        BEGIN
            SELECT
                regexp_replace(regexp_replace(JSON_VALUE(l_response, '$.response'),
                                              '```sql',
                                              '',
                                              1,
                                              0,
                                              'i'),
                               '```',
                               '',
                               1,
                               0,
                               'i')
            INTO l_sql
            FROM
                dual;

        EXCEPTION
            WHEN OTHERS THEN
                -- fallback: use whole response if JSON extraction failed
                l_sql := l_response;
        END;

        l_sql := trim(l_sql);

        -- If the model signalled it can't produce Oracle SQL
        IF l_sql = 'ERROR_NON_ORACLE_SQL' THEN
            RETURN 'Error: model indicated it could not produce Oracle SQL.';
        END IF;

        -- Quick validations for common non-Oracle constructs
        l_bad_tokens := '';
        IF regexp_like(l_sql, '\bLIMIT\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'LIMIT ';
        END IF;

        IF instr(l_sql, '`') > 0 THEN
            l_bad_tokens := l_bad_tokens || 'backticks(`) ';
        END IF;

        IF regexp_like(l_sql, '\bTOP\s+\d+', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'TOP N ';
        END IF;

        IF regexp_like(l_sql, '\bILIKE\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'ILIKE ';
        END IF;

        IF regexp_like(l_sql, '\bSERIAL\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'SERIAL ';
        END IF;

        IF regexp_like(l_sql, '\bARRAY_AGG\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'ARRAY_AGG ';
        END IF;

        IF
            l_bad_tokens IS NOT NULL
            AND length(trim(l_bad_tokens)) > 0
        THEN
            RETURN 'Error: Non-Oracle SQL elements detected: '
                   || trim(l_bad_tokens)
                   || ' | Raw Response: '
                   || substr(l_response, 1, 2000);
        END IF;

       -- After extracting l_sql, before returning:
        l_validation := validate_sql_syntax(l_sql);
        IF l_validation != 'VALID' THEN
            RETURN 'Error: Generated SQL failed validation: ' || l_validation;
        END IF;

        --audit log  
        ollama_audit_log_prc(p_table_name => upper(p_table_name), p_model => gc_default_model, p_user_prompt => p_user_prompt, p_request_body => l_payload
        , p_response_json => l_response,
                            p_generated_sql => l_sql, p_status => gc_success_status, p_error_message => NULL);

        -- Final trim and return
        RETURN l_sql;
    EXCEPTION
        WHEN OTHERS THEN
        --audit log  
            ollama_audit_log_prc(p_table_name => upper(p_table_name), p_model => gc_default_model, p_user_prompt => p_user_prompt, p_request_body => l_payload
            , p_generated_sql => l_sql,
                                p_status => gc_fail_status, p_error_message => 'Error: '
                                                                               || sqlerrm
                                                                               || ' | Raw Response: '
                                                                               || substr(l_response, 1, 1000));

            RETURN 'Error: '
                   || sqlerrm
                   || ' | Raw Response: '
                   || substr(l_response, 1, 1000);

    END generate_sql_from_ollama;

    /*
    * FUNCTION: get_ollama_insight
    * Gets AI-powered insights and analysis using Ollama
    */
    FUNCTION get_ollama_insight (
        p_model    IN VARCHAR2,
        p_question IN VARCHAR2
    ) RETURN CLOB AS
        l_payload  CLOB;
        l_response CLOB;
        l_insight  CLOB;
    BEGIN
        -- Build JSON payload
        apex_json.initialize_clob_output;
        apex_json.open_object;
        apex_json.write('model', p_model);
        apex_json.write('prompt', 'You are an expert analyst. '
                                  || 'Answer the following question in one concise, readable paragraph only. '
                                  || 'Question: '
                                  || p_question);
        apex_json.write('stream', FALSE); -- disable streaming
        apex_json.close_object;
        l_payload := apex_json.get_clob_output;
        apex_json.free_output;

          apex_web_service.set_request_headers(
            p_name_01        => 'Content-Type',
            p_value_01       => 'application/json',
            p_name_02        => 'User-Agent',
            p_value_02       => 'APEX',
            p_name_03        => 'X-API-Key',
            p_value_03       => gc_ollama_api_key);

    
         -- Call Ollama REST API
        l_response := apex_web_service.make_rest_request(p_url => gc_ollama_endpoint, p_http_method => 'POST', p_body => l_payload);

        -- Extract the insight text from JSON response
        l_insight := JSON_VALUE(l_response, '$.response');

        IF l_insight IS NULL THEN
        RETURN 'Error: Unable to extract insight from response';
        END IF;

         --audit log  
        ollama_audit_log_prc(p_model => gc_default_model, p_user_prompt => p_question, p_request_body => l_payload, p_response_json => l_response
        , p_status => gc_success_status,
                            p_error_message => NULL);

        -- Clean leading/trailing whitespace
        RETURN trim(l_insight);
    EXCEPTION
        WHEN OTHERS THEN
        --audit log  
            ollama_audit_log_prc(p_model => gc_default_model, p_user_prompt => p_question, p_request_body => l_payload, p_response_json => l_response
            , p_status => gc_fail_status,
                                p_error_message => NULL);

            RETURN 'Error: '
                   || sqlerrm
                   || ' | Raw Response: '
                   || substr(l_response, 1, 1000);

    END get_ollama_insight;

    /*
    * FUNCTION: validate_sql_syntax
    * Validates SQL syntax by attempting to parse it
    */
    FUNCTION validate_sql_syntax (
        p_sql IN CLOB
    ) RETURN VARCHAR2 IS

        l_cursor       INTEGER;
        l_sql_upper    VARCHAR2(32767);
        l_sql_trimmed  CLOB;
        l_open_count   INTEGER := 0;
        l_close_count  INTEGER := 0;
        l_quote_count  INTEGER := 0;
        l_dquote_count INTEGER := 0;
        i              INTEGER;
        l_len          INTEGER;
        l_char         VARCHAR2(1);
        l_prev_char    VARCHAR2(1) := '';
        l_in_string    BOOLEAN := FALSE;
        l_in_dquote    BOOLEAN := FALSE;
    BEGIN
        IF p_sql IS NULL OR trim(p_sql) = '' THEN
            RETURN 'ERROR: Empty SQL statement';
        END IF;

       -- Trim and normalize
        l_sql_trimmed := replace(trim(p_sql), ';', '');
        l_sql_upper := upper(substr(l_sql_trimmed, 1, 32767));
        l_len := length(l_sql_trimmed);

        -- ========== VALIDATION 1: Whitelist allowed statement types ==========
        IF NOT regexp_like(l_sql_upper, '^\s*(SELECT|INSERT|UPDATE|DELETE|MERGE|WITH)\s+', 'i') THEN
            RETURN 'ERROR: [V1] Only SELECT, INSERT, UPDATE, DELETE, MERGE, or WITH statements are allowed';
        END IF;

        -- ========== VALIDATION 2: Reject DDL statements ==========
        IF regexp_like(l_sql_upper, '\b(DROP|TRUNCATE|ALTER|CREATE|RENAME|FLASHBACK|COMMENT)\b', 'i') THEN
            RETURN 'ERROR: [V2] DDL operations are not permitted';
        END IF;

        -- ========== VALIDATION 3: Reject transaction control statements ==========
        IF regexp_like(l_sql_upper, '\b(GRANT|REVOKE|COMMIT|ROLLBACK|SAVEPOINT|LOCK|UNLOCK)\b', 'i') THEN
            RETURN 'ERROR: [V3] Transaction control operations are not permitted';
        END IF;

        -- ========== VALIDATION 4: Reject PL/SQL blocks ==========
        IF regexp_like(l_sql_upper, '\b(DECLARE|BEGIN|END|PROCEDURE|FUNCTION|PACKAGE|TRIGGER|CURSOR)\b', 'i') THEN
            RETURN 'ERROR: [V4] PL/SQL blocks are not permitted';
        END IF;

        -- ========== VALIDATION 5: Reject dynamic SQL execution ==========
        IF regexp_like(l_sql_upper, '\b(EXECUTE|DBMS_SQL|CALL|JAVA)\b', 'i') THEN
            RETURN 'ERROR: [V5] Dynamic SQL execution is not permitted';
        END IF;

        -- ========== VALIDATION 6: Check for SQL comments (injection risk) ==========
        IF instr(l_sql_upper, '/*') > 0 OR instr(l_sql_upper, '--') > 0 THEN
            RETURN 'ERROR: [V6] SQL comments (/* */ and --) are not permitted';
        END IF;

        -- ========== VALIDATION 7: Check for balanced quotes and double quotes ==========
        FOR i IN 1..l_len LOOP
            l_char := substr(l_sql_trimmed, i, 1);
            IF
                l_char = ''''
                AND l_prev_char != '\'
            THEN
                l_quote_count := l_quote_count + 1;
            ELSIF l_char = '"' THEN
                l_dquote_count := l_dquote_count + 1;
            END IF;

            l_prev_char := l_char;
        END LOOP;

        IF MOD(l_quote_count, 2) != 0 THEN
            RETURN 'ERROR: [V7] Unbalanced single quotes detected (count: '
                   || l_quote_count
                   || ')';
        END IF;

        IF MOD(l_dquote_count, 2) != 0 THEN
            RETURN 'ERROR: [V7] Unbalanced double quotes detected (count: '
                   || l_dquote_count
                   || ')';
        END IF;

        -- ========== VALIDATION 8: Check for balanced parentheses ==========
        FOR i IN 1..l_len LOOP
            l_char := substr(l_sql_trimmed, i, 1);
            IF l_char = '(' THEN
                l_open_count := l_open_count + 1;
            ELSIF l_char = ')' THEN
                l_close_count := l_close_count + 1;
            END IF;

        END LOOP;

        IF l_open_count != l_close_count THEN
            RETURN 'ERROR: [V8] Unbalanced parentheses (open: '
                   || l_open_count
                   || ', close: '
                   || l_close_count
                   || ')';
        END IF;

        IF
            l_close_count > 0
            AND l_close_count < l_open_count
        THEN
            RETURN 'ERROR: [V8] Closing parenthesis before opening parenthesis detected';
        END IF;

        -- ========== VALIDATION 9: Check for multiple statements ==========
        IF ( length(l_sql_trimmed) - length(replace(l_sql_trimmed, ';', '')) ) > 1 THEN
            RETURN 'ERROR: [V9] Multiple SQL statements detected; only one statement allowed';
        END IF;

        -- ========== VALIDATION 10: Detect non-Oracle SQL syntax ==========
        IF regexp_like(l_sql_upper, '\bLIMIT\s+\d+', 'i') THEN
            RETURN 'ERROR: [V10] LIMIT is not Oracle syntax; use FETCH FIRST n ROWS ONLY or ROWNUM';
        END IF;
        IF regexp_like(l_sql_upper, '\bTOP\s+\d+', 'i') THEN
            RETURN 'ERROR: [V10] TOP is not Oracle syntax; use FETCH FIRST n ROWS ONLY';
        END IF;
        IF regexp_like(l_sql_upper, '\bILIKE\b', 'i') THEN
            RETURN 'ERROR: [V10] ILIKE is not Oracle syntax; use LIKE or REGEXP_LIKE';
        END IF;
        IF instr(l_sql_upper, 'ARRAY_AGG') > 0 THEN
            RETURN 'ERROR: [V10] ARRAY_AGG is not Oracle syntax; use LISTAGG or JSON_ARRAYAGG';
        END IF;
        IF instr(l_sql_trimmed, '`') > 0 THEN
            RETURN 'ERROR: [V10] Backticks (`) are not Oracle syntax; use double quotes for identifiers';
        END IF;
        IF regexp_like(l_sql_upper, '\bSERIAL\b', 'i') THEN
            RETURN 'ERROR: [V10] SERIAL is not Oracle syntax; use SEQUENCE';
        END IF;

        -- ========== VALIDATION 11: Prevent unrestricted UPDATE/DELETE ==========
        IF regexp_like(l_sql_upper, '^\s*UPDATE\s+', 'i') THEN
            IF NOT regexp_like(l_sql_upper, '\bWHERE\b', 'i') THEN
                RETURN 'ERROR: [V11] UPDATE without WHERE clause is not permitted (data safety)';
            END IF;
        END IF;

        IF regexp_like(l_sql_upper, '^\s*DELETE\s+FROM\s+', 'i') THEN
            IF NOT regexp_like(l_sql_upper, '\bWHERE\b', 'i') THEN
                RETURN 'ERROR: [V11] DELETE without WHERE clause is not permitted (data safety)';
            END IF;
        END IF;

        -- ========== VALIDATION 12: Detect injection patterns ==========
        /*IF REGEXP_LIKE(l_sql_upper, 'UNION\s+(ALL\s+)?SELECT', 'i') AND INSTR(l_sql_upper, 'WHERE') = 0 THEN
            RETURN 'ERROR: [V12] UNION SELECT without WHERE detected (possible injection)';
        END IF;*/

        IF regexp_like(l_sql_upper, '\bOR\s+''1''=''1''', 'i') THEN
            RETURN 'ERROR: [V12] Classic SQL injection pattern detected';
        END IF;
        IF regexp_like(l_sql_upper, '\bOR\s+1=1', 'i') THEN
            RETURN 'ERROR: [V12] SQL injection pattern (1=1) detected';
        END IF;

        -- ========== VALIDATION 13: Check for suspicious schema access ==========
        IF
            regexp_like(l_sql_upper, '\b(SYS|SYSTEM|DBMS|ALL_|USER_|DBA_)\$?[A-Z_]+', 'i')
            AND regexp_like(l_sql_upper, 'SELECT.*FROM.*\b(SYS|SYSTEM|DBA_)', 'i')
        THEN
            RETURN 'ERROR: [V13] Access to system/admin objects is not permitted';
        END IF;

        -- ========== VALIDATION 14: Validate proper SQL termination ==========
       -- Validate ending character is only a letter or digit
        IF NOT regexp_like(l_sql_trimmed, '[A-Za-z0-9]$') THEN
            RETURN 'ERROR: [V14] SQL statement must end with a letter or number';
        END IF;

        -- ========== VALIDATION 15: Check for malformed keywords ==========
        IF regexp_like(l_sql_upper, '\bFROM\s+FROM\b', 'i') OR regexp_like(l_sql_upper, '\bWHERE\s+WHERE\b', 'i') OR regexp_like(l_sql_upper
        , '\bAND\s+AND\b', 'i') OR regexp_like(l_sql_upper, '\bOR\s+OR\b', 'i') OR regexp_like(l_sql_upper, '\bJOIN\s+JOIN\b', 'i') THEN
            RETURN 'ERROR: [V15] Duplicate/malformed keywords detected';
        END IF;

        -- ========== VALIDATION 16: Parse SQL syntax with DBMS_SQL ==========
        l_cursor := dbms_sql.open_cursor;
        BEGIN
            dbms_sql.parse(l_cursor, l_sql_trimmed, dbms_sql.native);
            dbms_sql.close_cursor(l_cursor);

            RETURN 'VALID';
        EXCEPTION
            WHEN OTHERS THEN
                IF dbms_sql.is_open(l_cursor) THEN
                    dbms_sql.close_cursor(l_cursor);
                END IF;

                RETURN 'ERROR: [V16] '
                       || sqlerrm
                       || l_sql_trimmed;
        END;

    END validate_sql_syntax;

    /*
    * PROCEDURE: execute_generated_sql
    * End-to-end workflow: Generate SQL from natural language and execute it
    */
    PROCEDURE execute_generated_sql (
        p_table_name  IN VARCHAR2 DEFAULT NULL,
        p_user_prompt IN VARCHAR2,
        p_results     OUT CLOB,
        p_status      OUT VARCHAR2,
        p_error_msg   OUT VARCHAR2
    ) IS
        l_generated_sql CLOB;
        l_validation    VARCHAR2(4000);
    BEGIN
        p_results := NULL;
        p_status := 'SUCCESS';
        p_error_msg := NULL;

        -- Step 1: Generate SQL from natural language
        l_generated_sql := generate_sql_from_ollama(p_table_name, p_user_prompt);

        -- Check for generation errors
        IF l_generated_sql LIKE 'Error:%' THEN
            p_status := 'ERROR';
            p_error_msg := 'SQL Generation Failed: ' || l_generated_sql;
            RETURN;
        END IF;

        -- Step 2: Validate SQL syntax
        l_validation := validate_sql_syntax(l_generated_sql);
        IF l_validation != 'VALID' THEN
            p_status := 'ERROR';
            p_error_msg := 'SQL Validation Failed: '
                           || l_validation
                           || ' | SQL: '
                           || l_generated_sql;
            RETURN;
        END IF;

        -- Step 3: Execute and get results as JSON
        BEGIN
            p_results := query_to_json_array(replace(l_generated_sql, ';', ''));

            -- Check if execution resulted in error
            IF p_results LIKE '{"error":%' THEN
                p_status := 'ERROR';
                p_error_msg := substr(p_results, 1, 4000);
                p_results := NULL;
            END IF;

             --audit log  
            ollama_audit_log_prc(p_model => gc_default_model, p_user_prompt => p_user_prompt, p_request_body => NULL, p_response_json => p_results
            , p_generated_sql => l_generated_sql,
                                p_status => gc_success_status, p_error_message => NULL);

        EXCEPTION
            WHEN OTHERS THEN

             --audit log  
                ollama_audit_log_prc(p_model => gc_default_model, p_user_prompt => p_user_prompt, p_request_body => NULL, p_response_json => NULL
                , p_generated_sql => l_generated_sql,
                                    p_status => gc_fail_status, p_error_message => NULL);

                p_status := 'ERROR';
                p_error_msg := 'Execution Failed: '
                               || sqlerrm
                               || ' | SQL: '
                               || l_generated_sql;
        END;

    EXCEPTION
        WHEN OTHERS THEN
            p_status := 'ERROR';
            p_error_msg := 'Unexpected Error: Check Logs' || sqlerrm;
    END execute_generated_sql;

END pkg_ollama;
/
