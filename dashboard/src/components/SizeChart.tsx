"use client";

import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
} from "recharts";
import { formatBytes } from "@/lib/utils";

interface DataPoint {
  date: string;
  totalSizeBytes: number;
  runCount: number;
}

export function SizeChart({ data }: { data: DataPoint[] }) {
  if (data.length === 0) {
    return (
      <div className="h-48 flex items-center justify-center text-muted-foreground text-sm">
        No data yet
      </div>
    );
  }

  return (
    <ResponsiveContainer width="100%" height={200}>
      <LineChart data={data} margin={{ top: 4, right: 4, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="hsl(240 4% 20%)" />
        <XAxis
          dataKey="date"
          stroke="hsl(240 5% 65%)"
          tick={{ fontSize: 10 }}
          tickLine={false}
        />
        <YAxis
          stroke="hsl(240 5% 65%)"
          tickFormatter={(v) => formatBytes(v)}
          tick={{ fontSize: 10 }}
          tickLine={false}
          width={60}
        />
        <Tooltip
          formatter={(v: number) => [formatBytes(v), "Size"]}
          contentStyle={{
            backgroundColor: "hsl(240 10% 7%)",
            border: "1px solid hsl(240 4% 20%)",
            borderRadius: "6px",
            fontSize: "12px",
            color: "hsl(0 0% 98%)",
          }}
        />
        <Line
          type="monotone"
          dataKey="totalSizeBytes"
          stroke="hsl(217 91% 60%)"
          strokeWidth={2}
          dot={{ r: 3, fill: "hsl(217 91% 60%)" }}
          activeDot={{ r: 5 }}
        />
      </LineChart>
    </ResponsiveContainer>
  );
}
