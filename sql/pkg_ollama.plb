create or replace PACKAGE BODY pkg_ollama AS

    -- Constants for configuration
    gc_ollama_endpoint CONSTANT VARCHAR2(500) := 'https://oci.dropletssoftware.com/ollama/api/generate';
    gc_default_model   CONSTANT VARCHAR2(100) := 'llama3.1:8b';

    /*
    * FUNCTION: query_to_json_array
    * Converts any SELECT query results to JSON array format
    */
    FUNCTION query_to_json_array (
        p_query IN CLOB
    ) RETURN NCLOB IS
        l_sql   CLOB;
        l_json  CLOB;
        l_out   NCLOB;
    BEGIN
        IF p_query IS NULL OR TRIM(p_query) = '' THEN
            RAISE_APPLICATION_ERROR(-20020, 'p_query is required and must be a SELECT statement');
        END IF;

        -- Build JSON aggregation SQL
        l_sql :=
            'SELECT COALESCE(' ||
            '  JSON_ARRAYAGG(JSON_OBJECT(*) RETURNING CLOB),' ||
            '  TO_CLOB(''[]'')' ||
            ') AS j FROM (' || p_query || ') q';

        -- Execute and fetch as CLOB
        EXECUTE IMMEDIATE l_sql INTO l_json;

        -- Convert explicitly to NCLOB before returning
        l_out := TO_NCLOB(l_json);

        RETURN l_out;

    EXCEPTION
        WHEN OTHERS THEN
            RETURN TO_NCLOB('{"error":"' || REPLACE(SQLERRM, '"', '\"') || '"}');
    END query_to_json_array;

    /*
    * FUNCTION: generate_sql_from_ollama
    * Generates Oracle SQL from natural language prompts using Ollama AI
    */
    FUNCTION generate_sql_from_ollama (
        p_table_name  IN VARCHAR2 DEFAULT NULL,
        p_user_prompt IN VARCHAR2
    ) RETURN CLOB
    AS
        l_metadata_json   CLOB;
        l_payload         CLOB;
        l_response        CLOB;
        l_sql             CLOB;
        l_bad_tokens      VARCHAR2(4000);
        l_system_prompt   CLOB;
    BEGIN
        -- Build schema metadata if table provided
        IF p_table_name IS NOT NULL THEN
            SELECT JSON_ARRAYAGG(
                       JSON_OBJECT(
                           'column_name' VALUE column_name,
                           'data_type'   VALUE data_type,
                           'data_length' VALUE data_length
                       )
                   RETURNING CLOB)
            INTO l_metadata_json
            FROM all_tab_columns
            WHERE table_name = UPPER(p_table_name)
              AND owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
        ELSE
            l_metadata_json := '[]';
        END IF;

        -- Strong system prompt: force Oracle SQL dialect only
        l_system_prompt := 'You are an expert Oracle SQL generator. STRICT RULES:' || CHR(10) ||
                           '- Return ONLY valid Oracle SQL statements (compatible with Oracle 19c/21c). No explanations, no comments, no surrounding text, no markdown, no code fences (```).' || CHR(10) ||
                           '- Use Oracle idioms where appropriate (FROM DUAL for constant selects, NVL, TO_DATE, TO_CHAR, ROWNUM or FETCH FIRST ... ROWS ONLY for limiting). Do NOT use LIMIT, backticks (`), TOP, ILIKE, SERIAL, or Postgres/MySQL-specific functions.' || CHR(10) ||
                           '- Use standard Oracle functions and datatypes. Do NOT invent vendor-specific syntax from other databases.' || CHR(10) ||
                           '- If you cannot produce valid Oracle SQL, respond with exactly: ERROR_NON_ORACLE_SQL' || CHR(10) ||
                           '- Return only the SQL; nothing else.';

        -- Build JSON payload safely using APEX_JSON
        APEX_JSON.initialize_clob_output;
        APEX_JSON.open_object;

        -- Model selection
        APEX_JSON.write('model', gc_default_model);

        -- Provide the system message separately (Ollama supports `system` parameter)
        APEX_JSON.write('system', l_system_prompt);

        -- Build the prompt that includes the user's request and optional schema
        APEX_JSON.write('prompt',
            'User prompt: ' || CHR(10) || p_user_prompt ||
            CASE WHEN p_table_name IS NOT NULL
                 THEN CHR(10) || CHR(10) || 'Schema metadata (JSON):' || CHR(10) || l_metadata_json
                 ELSE ''
            END ||
            CHR(10) || CHR(10) ||
            'IMPORTANT: Output must be a single SQL statement or a set of SQL statements separated by semicolons, each valid Oracle SQL. No markdown, no explanations.'
        );

        -- Deterministic options: temperature 0 to reduce hallucinations / dialect drift
        APEX_JSON.open_object('options');
        APEX_JSON.write('temperature', 0);
        APEX_JSON.close_object;

        -- Disable streaming so we get the full response in one object
        APEX_JSON.write('stream', FALSE);

        APEX_JSON.close_object;
        l_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;

        -- Call Ollama REST API
        l_response := APEX_WEB_SERVICE.make_rest_request(
            p_url         => gc_ollama_endpoint,
            p_http_method => 'POST',
            p_body        => l_payload
        );

        -- Extract model response (final non-streamed response lives in $.response)
        BEGIN
            SELECT REGEXP_REPLACE(
                       REGEXP_REPLACE(
                           json_value(l_response, '$.response'),
                           '```sql', '', 1, 0, 'i'
                       ),
                       '```', '', 1, 0, 'i'
                   )
            INTO l_sql
            FROM dual;
        EXCEPTION
            WHEN OTHERS THEN
                -- fallback: use whole response if JSON extraction failed
                l_sql := l_response;
        END;

        l_sql := TRIM(l_sql);

        -- If the model signalled it can't produce Oracle SQL
        IF l_sql = 'ERROR_NON_ORACLE_SQL' THEN
            RETURN 'Error: model indicated it could not produce Oracle SQL.';
        END IF;

        -- Quick validations for common non-Oracle constructs
        l_bad_tokens := '';

        IF REGEXP_LIKE(l_sql, '\bLIMIT\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'LIMIT ';
        END IF;
        IF INSTR(l_sql, '`') > 0 THEN
            l_bad_tokens := l_bad_tokens || 'backticks(`) ';
        END IF;
        IF REGEXP_LIKE(l_sql, '\bTOP\s+\d+', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'TOP N ';
        END IF;
        IF REGEXP_LIKE(l_sql, '\bILIKE\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'ILIKE ';
        END IF;
        IF REGEXP_LIKE(l_sql, '\bSERIAL\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'SERIAL ';
        END IF;
        IF REGEXP_LIKE(l_sql, '\bARRAY_AGG\b', 'i') THEN
            l_bad_tokens := l_bad_tokens || 'ARRAY_AGG ';
        END IF;

        IF l_bad_tokens IS NOT NULL AND LENGTH(TRIM(l_bad_tokens)) > 0 THEN
            RETURN 'Error: Non-Oracle SQL elements detected: ' || TRIM(l_bad_tokens)
                   || ' | Raw Response: ' || SUBSTR(l_response, 1, 2000);
        END IF;

        -- Final trim and return
        RETURN l_sql;

    EXCEPTION
        WHEN OTHERS THEN
            RETURN 'Error: ' || SQLERRM || ' | Raw Response: ' || SUBSTR(l_response, 1, 1000);
    END generate_sql_from_ollama;

    /*
    * FUNCTION: get_ollama_insight
    * Gets AI-powered insights and analysis using Ollama
    */
    FUNCTION get_ollama_insight (
        p_model    IN VARCHAR2,
        p_question IN VARCHAR2
    ) RETURN CLOB
    AS
        l_payload  CLOB;
        l_response CLOB;
        l_insight  CLOB;
    BEGIN
        -- Build JSON payload
        APEX_JSON.initialize_clob_output;
        APEX_JSON.open_object;
        APEX_JSON.write('model', p_model);
        APEX_JSON.write('prompt',
            'You are an expert analyst. ' ||
            'Answer the following question in one concise, readable paragraph only. ' ||
            'Question: ' || p_question
        );
        APEX_JSON.write('stream', false); -- disable streaming
        APEX_JSON.close_object;
        l_payload := APEX_JSON.get_clob_output;
        APEX_JSON.free_output;

        -- Call Ollama REST API
        l_response := APEX_WEB_SERVICE.make_rest_request(
                          p_url         => gc_ollama_endpoint,
                          p_http_method => 'POST',
                          p_body        => l_payload,
                          p_parm_name   => APEX_UTIL.STRING_TO_TABLE('Content-Type: application/json'),
                          p_parm_value  => APEX_UTIL.STRING_TO_TABLE('application/json')
                      );

        -- Extract the insight text from JSON response
        l_insight := json_value(l_response, '$.response');

        -- Clean leading/trailing whitespace
        RETURN TRIM(l_insight);

    EXCEPTION
        WHEN OTHERS THEN
            RETURN 'Error: ' || SQLERRM || ' | Raw Response: ' || SUBSTR(l_response, 1, 1000);
    END get_ollama_insight;

    /*
    * FUNCTION: validate_sql_syntax
    * Validates SQL syntax by attempting to parse it
    */
    FUNCTION validate_sql_syntax (
        p_sql IN CLOB
    ) RETURN VARCHAR2
    IS
        l_cursor INTEGER;
        l_dummy  INTEGER;
    BEGIN
        IF p_sql IS NULL OR TRIM(p_sql) = '' THEN
            RETURN 'ERROR: Empty SQL statement';
        END IF;

        -- Try to parse the SQL
        l_cursor := DBMS_SQL.OPEN_CURSOR;
        BEGIN
            DBMS_SQL.PARSE(l_cursor, p_sql, DBMS_SQL.NATIVE);
            DBMS_SQL.CLOSE_CURSOR(l_cursor);
            RETURN 'VALID';
        EXCEPTION
            WHEN OTHERS THEN
                IF DBMS_SQL.IS_OPEN(l_cursor) THEN
                    DBMS_SQL.CLOSE_CURSOR(l_cursor);
                END IF;
                RETURN 'ERROR: ' || SQLERRM;
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
    )
    IS
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
            p_error_msg := 'SQL Validation Failed: ' || l_validation || ' | SQL: ' || l_generated_sql;
            RETURN;
        END IF;

        -- Step 3: Execute and get results as JSON
        BEGIN
            p_results := query_to_json_array(l_generated_sql);
            
            -- Check if execution resulted in error
            IF p_results LIKE '{"error":%' THEN
                p_status := 'ERROR';
                p_error_msg := SUBSTR(p_results, 1, 4000);
                p_results := NULL;
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                p_status := 'ERROR';
                p_error_msg := 'Execution Failed: ' || SQLERRM || ' | SQL: ' || l_generated_sql;
        END;

    EXCEPTION
        WHEN OTHERS THEN
            p_status := 'ERROR';
            p_error_msg := 'Unexpected Error: ' || SQLERRM;
    END execute_generated_sql;

END pkg_ollama;
/