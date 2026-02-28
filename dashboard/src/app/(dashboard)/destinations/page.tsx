import { apiGet } from "@/lib/api-client";
import { formatTs } from "@/lib/utils";
import { DestinationForm } from "@/components/DestinationForm";

interface Destination {
  id: number;
  name: string;
  type: "s3" | "sftp";
  enabled: boolean;
  hostOrEndpoint: string | null;
  port: number | null;
  bucketOrPath: string | null;
  accessKeyOrUser: string | null;
  secretName: string | null;
  region: string | null;
  pathPrefix: string | null;
  sftpAuthType: string | null;
  createdAt: string;
}

function S3Badge() {
  return <span className="text-xs px-1.5 py-0.5 rounded bg-blue-400/15 text-blue-400 border border-blue-400/30 font-medium">S3</span>;
}

function SftpBadge() {
  return <span className="text-xs px-1.5 py-0.5 rounded bg-purple-400/15 text-purple-400 border border-purple-400/30 font-medium">SFTP</span>;
}

export default async function DestinationsPage() {
  let destinations: Destination[] = [];
  let error: string | null = null;

  try {
    destinations = await apiGet<Destination[]>("/destinations");
  } catch (err) {
    error = String(err);
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">Destinations</h1>
          <p className="text-sm text-muted-foreground mt-0.5">S3 and SFTP upload targets</p>
        </div>
      </div>

      {error && (
        <div className="bg-destructive/10 border border-destructive/30 rounded-lg p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      {/* Existing destinations */}
      {destinations.length > 0 && (
        <div className="space-y-3">
          {destinations.map((dest) => (
            <div key={dest.id} className="bg-card border border-border rounded-lg p-5">
              <div className="flex items-start justify-between gap-4">
                <div className="flex items-center gap-3">
                  {dest.type === "s3" ? <S3Badge /> : <SftpBadge />}
                  <div>
                    <p className="font-medium text-foreground text-sm">{dest.name}</p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {dest.hostOrEndpoint}
                      {dest.bucketOrPath ? ` / ${dest.bucketOrPath}` : ""}
                      {dest.pathPrefix ? ` / ${dest.pathPrefix}` : ""}
                    </p>
                  </div>
                </div>
                <div className="flex items-center gap-2 shrink-0">
                  <span className={`text-xs px-2 py-0.5 rounded-full border
                    ${dest.enabled
                      ? "bg-emerald-400/10 text-emerald-400 border-emerald-400/30"
                      : "bg-muted text-muted-foreground border-border"}`}>
                    {dest.enabled ? "Enabled" : "Disabled"}
                  </span>
                  <span className="text-xs text-muted-foreground">ID #{dest.id}</span>
                </div>
              </div>

              <div className="mt-3 grid grid-cols-2 sm:grid-cols-3 gap-3 text-xs">
                {dest.type === "s3" && dest.region && (
                  <div><span className="text-muted-foreground">Region: </span><span className="text-foreground">{dest.region}</span></div>
                )}
                {dest.type === "sftp" && dest.sftpAuthType && (
                  <div><span className="text-muted-foreground">Auth: </span><span className="text-foreground">{dest.sftpAuthType}</span></div>
                )}
                {dest.secretName && (
                  <div><span className="text-muted-foreground">Secret: </span><code className="text-foreground">{dest.secretName}</code></div>
                )}
                <div><span className="text-muted-foreground">Added: </span><span className="text-foreground">{formatTs(dest.createdAt)}</span></div>
              </div>
            </div>
          ))}
        </div>
      )}

      {destinations.length === 0 && !error && (
        <div className="bg-card border border-border rounded-lg p-8 text-center">
          <p className="text-muted-foreground text-sm">No destinations configured yet.</p>
          <p className="text-xs text-muted-foreground mt-1">Add an S3 or SFTP destination below.</p>
        </div>
      )}

      {/* Add destination form */}
      <div className="bg-card border border-border rounded-lg p-5">
        <h2 className="text-sm font-semibold text-foreground mb-4">Add Destination</h2>
        <DestinationForm />
      </div>
    </div>
  );
}
