-- Example 1: Generate SQL for a table
DECLARE
    l_sql CLOB;
BEGIN
    l_sql := pkg_ollama.generate_sql_from_ollama(
        p_table_name => 'EMPLOYEES:DEPARTMENTS',
        p_user_prompt => 'show top 5 paid staff and the department name'
    );
    DBMS_OUTPUT.PUT_LINE('Generated SQL: ' || l_sql);
END;
/

-- Example 2: Complete workflow to generate sql, execution and return the json results
DECLARE
    l_results CLOB;
    l_status  VARCHAR2(100);
    l_error   VARCHAR2(4000);
BEGIN
    pkg_ollama.execute_generated_sql(
        p_table_name => 'EMPLOYEES:DEPARTMENTS',
        p_user_prompt => 'show top 5 paid staff and the department name',
        p_results => l_results,
        p_status => l_status,
        p_error_msg => l_error
    );
    
    IF l_status = 'SUCCESS' THEN
        DBMS_OUTPUT.PUT_LINE('Results: ' || l_results);
    ELSE
        DBMS_OUTPUT.PUT_LINE('Error: ' || l_error);
    END IF;
END;
/


-- Example 3: Get AI insights
DECLARE
    l_insight CLOB;
BEGIN
    l_insight := pkg_ollama.get_ollama_insight(
        p_model => 'llama3.1:8b',
        p_question => 'What are the benefits of cloud data warehouses?'
    );
    DBMS_OUTPUT.PUT_LINE('Insight: ' || l_insight);
END;
/