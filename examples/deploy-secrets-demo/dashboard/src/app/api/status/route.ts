import { NextResponse } from 'next/server';
import { parseVaultFile } from '@/lib/vault';
import Redis from 'ioredis';
import { Client } from 'pg';

interface ServiceStatus {
  connected: boolean;
  error?: string;
}

interface StatusResponse {
  redis: ServiceStatus;
  postgres: ServiceStatus;
  timestamp: string;
}

async function checkRedis(): Promise<ServiceStatus> {
  let redis: Redis | null = null;
  try {
    const creds = parseVaultFile('/vault/secrets/redis-creds');
    const host = process.env.REDIS_HOST || 'redis';
    redis = new Redis({
      host,
      port: 6379,
      password: creds.password,
      connectTimeout: 5000,
      lazyConnect: true,
    });
    await redis.connect();
    await redis.ping();
    return { connected: true };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return { connected: false, error: message };
  } finally {
    if (redis) {
      try { redis.disconnect(); } catch {}
    }
  }
}

async function checkPostgres(): Promise<ServiceStatus> {
  let client: Client | null = null;
  try {
    const creds = parseVaultFile('/vault/secrets/postgres-creds');
    const host = process.env.POSTGRES_HOST || 'postgres';
    client = new Client({
      host,
      port: 5432,
      user: creds.username,
      password: creds.password,
      database: creds.database,
      connectionTimeoutMillis: 5000,
    });
    await client.connect();
    await client.query('SELECT 1');
    return { connected: true };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return { connected: false, error: message };
  } finally {
    if (client) {
      try { await client.end(); } catch {}
    }
  }
}

export const dynamic = 'force-dynamic';

export async function GET() {
  const [redis, postgres] = await Promise.all([checkRedis(), checkPostgres()]);

  const response: StatusResponse = {
    redis,
    postgres,
    timestamp: new Date().toISOString(),
  };

  return NextResponse.json(response);
}
