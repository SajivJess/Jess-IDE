import pg from 'pg';

export function createPool(connectionString: string, schema?: string): pg.Pool {
  return new pg.Pool({
    connectionString,
    max: 8,
    connectionTimeoutMillis: 2000,
    idleTimeoutMillis: 10000,
    statement_timeout: 5000,
    query_timeout: 6000,
    ...(schema ? { options: `-c search_path=${schema}` } : {}),
  });
}
