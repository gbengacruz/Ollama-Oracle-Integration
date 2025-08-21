
CREATE OR REPLACE FUNCTION FN_OLLAMA_GENAI (
  p_table_name    IN VARCHAR2 DEFAULT NULL,
  p_user_prompt   IN CLOB,
  p_model         IN VARCHAR2 DEFAULT 'llama3.1:8b',
  p_ollama_host   IN VARCHAR2 DEFAULT 'https://oci.dropletssoftware.com/ollama',
  p_response_mode IN PLS_INTEGER DEFAULT 3  -- 1 = concise human-readable only, 2 = JSON only, 3 = both (default)
) RETURN CLOB
AUTHID DEFINER
IS
  l_context       CLOB := EMPTY_CLOB();
  l_request_body  CLOB := EMPTY_CLOB();
  l_response      CLOB := EMPTY_CLOB();
  l_result        CLOB := EMPTY_CLOB();
  v_prompt_text   CLOB := EMPTY_CLOB();
  v_mode_text     VARCHAR2(4000);

  FUNCTION escape_json(p_text CLOB) RETURN CLOB IS
    v CLOB := p_text;
  BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    v := REPLACE(v, '\', '\\');
    v := REPLACE(v, '"', '\"');
    v := REPLACE(v, CHR(13)||CHR(10), '\n');
    v := REPLACE(v, CHR(10), '\n');
    v := REPLACE(v, CHR(13), '\n');
    v := REPLACE(v, CHR(9), '\t');
    RETURN v;
  END escape_json;

BEGIN
  -- validate response mode
  IF p_response_mode NOT IN (1,2,3) THEN
    RAISE_APPLICATION_ERROR(-20061, 'p_response_mode must be 1, 2 or 3.');
  END IF;

  -- Build schema context only if a table name was supplied
  IF p_table_name IS NOT NULL THEN
    DBMS_LOB.CREATETEMPORARY(l_context, TRUE);
    DBMS_LOB.WRITEAPPEND(l_context,
      LENGTH('Table: ' || p_table_name || CHR(10) || 'Columns:' || CHR(10)),
      'Table: ' || p_table_name || CHR(10) || 'Columns:' || CHR(10)
    );

    FOR r IN (
      SELECT column_name, data_type
      FROM user_tab_columns
      WHERE table_name = UPPER(p_table_name)
      ORDER BY column_id
    ) LOOP
      DBMS_LOB.WRITEAPPEND(l_context,
        LENGTH('- ' || r.column_name || ' (' || r.data_type || ')' || CHR(10)),
        '- ' || r.column_name || ' (' || r.data_type || ')' || CHR(10)
      );
    END LOOP;

    IF DBMS_LOB.GETLENGTH(l_context) = 0 THEN
      RAISE_APPLICATION_ERROR(-20060,
        'Table "' || p_table_name || '" not found or has no columns in your schema.'
      );
    END IF;
  END IF;

  -- Decide instruction text based on requested response mode
  IF p_response_mode = 1 THEN
    v_mode_text := 'Reply with a concise human-readable answer only. Do NOT include JSON or extra commentary.';
  ELSIF p_response_mode = 2 THEN
    v_mode_text := 'Reply with a JSON summary only (a single JSON object). Do NOT include any extra text.';
  ELSE
    v_mode_text := 'First reply with a concise human-readable answer, then on a new line provide a small JSON summary (a single JSON object).';
  END IF;

  -- Build prompt text
  DBMS_LOB.CREATETEMPORARY(v_prompt_text, TRUE);
  DBMS_LOB.WRITEAPPEND(v_prompt_text,
    LENGTH('You are an expert Oracle data analyst. Use ONLY the schema context below.' || CHR(10) ||
           'QUESTION: ' || p_user_prompt || CHR(10) ||
           'CONTEXT:' || CHR(10)
    ),
    'You are an expert Oracle data analyst. Use ONLY the schema context below.' || CHR(10) ||
    'QUESTION: ' || p_user_prompt || CHR(10) ||
    'CONTEXT:' || CHR(10)
  );

  IF DBMS_LOB.GETLENGTH(l_context) > 0 THEN
    DBMS_LOB.WRITEAPPEND(v_prompt_text,
      DBMS_LOB.GETLENGTH(l_context),
      l_context
    );
    DBMS_LOB.WRITEAPPEND(v_prompt_text, LENGTH(CHR(10)), CHR(10));
  END IF;

  DBMS_LOB.WRITEAPPEND(v_prompt_text,
    LENGTH(v_mode_text) + 2,
    v_mode_text || CHR(10) || 'Keep answers precise and do not invent schema details.'
  );

  -- Build JSON request body
  DBMS_LOB.CREATETEMPORARY(l_request_body, TRUE);
  DBMS_LOB.WRITEAPPEND(l_request_body,
    LENGTH('{"model":"' || p_model || '","prompt":"'),
    '{"model":"' || p_model || '","prompt":"'
  );

  -- escape and append prompt
  DBMS_LOB.WRITEAPPEND(l_request_body,
    DBMS_LOB.GETLENGTH(escape_json(v_prompt_text)),
    escape_json(v_prompt_text)
  );

  DBMS_LOB.WRITEAPPEND(l_request_body, LENGTH('","stream":false}'), '","stream":false}');

  -- Headers
  apex_web_service.set_request_headers(
    p_name_01 => 'Content-Type',
    p_value_01 => 'application/json',
    p_reset    => TRUE
  );

  -- Call Ollama
  l_response := apex_web_service.make_rest_request(
    p_url         => RTRIM(p_ollama_host,'/') || '/api/generate',
    p_http_method => 'POST',
    p_body        => l_request_body
  );

  -- Extract response
  IF l_response IS NOT NULL AND JSON_EXISTS(l_response, '$.response') THEN
    l_result := JSON_VALUE(l_response, '$.response' RETURNING CLOB);

    -- 🔹 Remove triple backticks if they exist at start or end
    l_result := REGEXP_REPLACE(l_result, '^\\s*```[a-zA-Z]*\\s*', '');
    l_result := REGEXP_REPLACE(l_result, '\\s*```$', '');

    RETURN NVL(l_result, l_response);
  ELSE
    RETURN NVL(l_response, EMPTY_CLOB());
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    RAISE_APPLICATION_ERROR(-20999,
      'FN_OLLAMA_GENAI failed: ' || SQLERRM
    );
    RETURN EMPTY_CLOB(); -- satisfy compiler
END FN_OLLAMA_GENAI;
/
