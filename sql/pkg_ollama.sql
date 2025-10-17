create or replace PACKAGE pkg_ollama AS
    /*
    * Oracle AI Integration Package
    * Provides natural language to SQL generation and data analysis using Ollama
    * Author: Cruz Bello
    * Version: 1.0
    */

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
    ) ;

    -- Function 1: Convert any query result to JSON array
    FUNCTION query_to_json_array (
        p_query IN CLOB
    ) RETURN NCLOB;

    -- Function 2: Generate Oracle SQL from natural language using Ollama
    FUNCTION generate_sql_from_ollama (
        p_table_name  IN VARCHAR2 DEFAULT NULL,
        p_user_prompt IN VARCHAR2
    ) RETURN CLOB;

    -- Function 3: Get AI insights/analysis using Ollama
    FUNCTION get_ollama_insight (
        p_model    IN VARCHAR2,
        p_question IN VARCHAR2
    ) RETURN CLOB;

    -- Additional utility function: Validate generated SQL syntax
    FUNCTION validate_sql_syntax (
        p_sql IN CLOB
    ) RETURN VARCHAR2;

    -- Procedure: Execute and return results from generated SQL
    PROCEDURE execute_generated_sql (
        p_table_name  IN VARCHAR2 DEFAULT NULL,
        p_user_prompt IN VARCHAR2,
        p_results     OUT CLOB,
        p_status      OUT VARCHAR2,
        p_error_msg   OUT VARCHAR2
    );

END pkg_ollama;
/
