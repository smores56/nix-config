import {
  GetObjectCommand,
  ListObjectsV2Command,
  S3Client,
} from "@aws-sdk/client-s3";
import type { ResticBackend } from "./backend";

export type R2Options = {
  endpoint: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  region?: string;
  prefix?: string;
};

export function byteRange(offset: number, length?: number): string | undefined {
  if (length !== undefined) return `bytes=${offset}-${offset + length - 1}`;
  return offset > 0 ? `bytes=${offset}-` : undefined;
}

export function repositoryPrefix(repository: string, bucket: string): string {
  const url = repository.replace(/^s3:/, "");
  try {
    const parts = new URL(url).pathname.split("/").filter(Boolean);
    const index = parts.indexOf(bucket);
    return index === -1 ? "" : parts.slice(index + 1).join("/");
  } catch {
    return "";
  }
}

function timeoutOptions(): { abortSignal: AbortSignal } | undefined {
  if (typeof AbortSignal.timeout !== "function") return undefined;
  return { abortSignal: AbortSignal.timeout(20_000) };
}

export class R2Backend implements ResticBackend {
  private readonly client: S3Client;
  private readonly bucket: string;
  private readonly prefix: string;

  constructor(options: R2Options) {
    this.bucket = options.bucket;
    this.prefix = (options.prefix ?? "").replace(/^\/+|\/+$/g, "");
    this.client = new S3Client({
      region: options.region || "auto",
      endpoint: options.endpoint,
      forcePathStyle: true,
      credentials: {
        accessKeyId: options.accessKeyId,
        secretAccessKey: options.secretAccessKey,
      },
    });
  }

  private key(path: string): string {
    return this.prefix ? `${this.prefix}/${path}` : path;
  }

  async read(path: string, offset = 0, length?: number): Promise<Uint8Array> {
    const range = byteRange(offset, length);
    const response = await this.client.send(
      new GetObjectCommand({
        Bucket: this.bucket,
        Key: this.key(path),
        ...(range ? { Range: range } : {}),
      }),
      timeoutOptions(),
    );
    if (!response.Body) throw new Error(`empty R2 object: ${path}`);
    return new Uint8Array(await response.Body.transformToByteArray());
  }

  async list(prefix: string): Promise<string[]> {
    const keys: string[] = [];
    const base = this.prefix ? `${this.prefix}/` : "";
    let token: string | undefined;
    do {
      const response = await this.client.send(
        new ListObjectsV2Command({
          Bucket: this.bucket,
          Prefix: this.key(prefix),
          ContinuationToken: token,
        }),
        timeoutOptions(),
      );
      for (const object of response.Contents ?? []) {
        if (object.Key?.startsWith(base)) keys.push(object.Key.slice(base.length));
      }
      token = response.NextContinuationToken;
    } while (token);
    return keys;
  }
}
