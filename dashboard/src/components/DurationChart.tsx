"use client";

import {
  ResponsiveContainer,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
} from "recharts";
import { formatDuration } from "@/lib/utils";

interface DataPoint {
  date: string;
  avgDurationSeconds: number;
  maxDurationSeconds: number;
}

export function DurationChart({ data }: { data: DataPoint[] }) {
  if (data.length === 0) {
    return (
      <div className="h-48 flex items-center justify-center text-muted-foreground text-sm">
        No data yet
      </div>
    );
  }

  return (
    <ResponsiveContainer width="100%" height={200}>
      <BarChart data={data} margin={{ top: 4, right: 4, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="hsl(240 4% 20%)" />
        <XAxis
          dataKey="date"
          stroke="hsl(240 5% 65%)"
          tick={{ fontSize: 10 }}
          tickLine={false}
        />
        <YAxis
          stroke="hsl(240 5% 65%)"
          tickFormatter={(v) => formatDuration(v)}
          tick={{ fontSize: 10 }}
          tickLine={false}
          width={48}
        />
        <Tooltip
          formatter={(v: number, name: string) => [
            formatDuration(v),
            name === "avgDurationSeconds" ? "Avg" : "Max",
          ]}
          contentStyle={{
            backgroundColor: "hsl(240 10% 7%)",
            border: "1px solid hsl(240 4% 20%)",
            borderRadius: "6px",
            fontSize: "12px",
            color: "hsl(0 0% 98%)",
          }}
        />
        <Legend
          formatter={(v) => (v === "avgDurationSeconds" ? "Avg" : "Max")}
          wrapperStyle={{ fontSize: "10px" }}
        />
        <Bar dataKey="avgDurationSeconds" fill="hsl(217 91% 60%)" radius={[3, 3, 0, 0]} />
        <Bar dataKey="maxDurationSeconds" fill="hsl(217 91% 40%)" radius={[3, 3, 0, 0]} />
      </BarChart>
    </ResponsiveContainer>
  );
}
