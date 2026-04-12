import React, { useEffect, useState, useCallback, useMemo } from 'react';
// import { supabase } from '../lib/supabase';

// ─── Mock Data Generators (replace with Supabase RPC calls) ──────

/**
 * Supabase RPC: get_daily_active_users(days int)
 * SQL:
 *   SELECT date_trunc('day', last_active_at) AS day, COUNT(DISTINCT id) AS dau
 *   FROM users
 *   WHERE last_active_at >= NOW() - INTERVAL '30 days'
 *   GROUP BY 1 ORDER BY 1;
 */
function generateDAUData(days: number) {
  const data = [];
  const now = new Date();
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(now);
    d.setDate(d.getDate() - i);
    // Simulate growth from ~800 to ~2400 with weekly patterns
    const base = 800 + ((days - i) / days) * 1600;
    const dayOfWeek = d.getDay();
    const weekendDip = dayOfWeek === 0 || dayOfWeek === 6 ? 0.72 : 1;
    const noise = 0.85 + Math.random() * 0.3;
    data.push({
      date: d.toISOString().split('T')[0],
      label: `${d.getMonth() + 1}/${d.getDate()}`,
      value: Math.round(base * weekendDip * noise),
    });
  }
  return data;
}

/**
 * Supabase RPC: get_videos_published(days int)
 * SQL:
 *   SELECT date_trunc('day', published_at) AS day, COUNT(*) AS cnt
 *   FROM posts WHERE published_at >= NOW() - INTERVAL '14 days'
 *   GROUP BY 1 ORDER BY 1;
 */
function generateVideosData(days: number) {
  const data = [];
  const now = new Date();
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(now);
    d.setDate(d.getDate() - i);
    const base = 120 + Math.floor(Math.random() * 80);
    const dayOfWeek = d.getDay();
    const weekendBoost = dayOfWeek === 0 || dayOfWeek === 6 ? 1.4 : 1;
    data.push({
      date: d.toISOString().split('T')[0],
      label: `${d.getMonth() + 1}/${d.getDate()}`,
      value: Math.round(base * weekendBoost),
    });
  }
  return data;
}

/**
 * Supabase RPC: get_monthly_revenue(months int)
 * SQL:
 *   SELECT date_trunc('month', created_at) AS month,
 *          SUM(amount_cents) / 100.0 AS revenue
 *   FROM payments WHERE status = 'succeeded'
 *     AND created_at >= NOW() - INTERVAL '12 months'
 *   GROUP BY 1 ORDER BY 1;
 */
function generateRevenueData(months: number) {
  const data = [];
  const now = new Date();
  const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  for (let i = months - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    // Revenue ramp: Y1 target $150K → ~$12.5K/mo, building from ~$2K
    const progress = (months - i) / months;
    const base = 2000 + progress * 14000;
    const noise = 0.9 + Math.random() * 0.2;
    data.push({
      date: d.toISOString().split('T')[0],
      label: monthNames[d.getMonth()],
      value: Math.round(base * noise),
    });
  }
  return data;
}

/**
 * Supabase RPC: get_top_creators(limit int)
 * SQL:
 *   SELECT u.username, u.avatar_url,
 *          COUNT(p.id) AS videos_published,
 *          SUM(p.view_count) AS total_views,
 *          SUM(p.like_count) AS total_likes
 *   FROM users u JOIN posts p ON p.user_id = u.id
 *   WHERE p.published_at IS NOT NULL
 *   GROUP BY u.id ORDER BY total_views DESC LIMIT 10;
 */
function generateTopCreators() {
  const names = [
    'xStickMaster', 'AnimKing42', 'DeathLoop_GFX', 'SophiaAnimate',
    'PixelNinja99', 'StickFury_HD', 'MotionCraft', 'EpicStickBro',
    'VFX_Legend', 'AnimPulse',
  ];
  return names.map((username, i) => ({
    rank: i + 1,
    username,
    videos: Math.floor(280 - i * 22 + Math.random() * 15),
    views: Math.floor((500000 - i * 45000) * (0.85 + Math.random() * 0.3)),
    likes: Math.floor((42000 - i * 3800) * (0.85 + Math.random() * 0.3)),
  }));
}

/**
 * Supabase RPC: get_platform_distribution()
 * SQL:
 *   SELECT target_platform, COUNT(*) AS cnt
 *   FROM posts WHERE published_at IS NOT NULL
 *   GROUP BY target_platform;
 */
function generatePlatformData() {
  return [
    { platform: 'YouTube', pct: 34, color: '#ef4444' },
    { platform: 'TikTok', pct: 28, color: '#06b6d4' },
    { platform: 'Instagram', pct: 22, color: '#a855f7' },
    { platform: 'X / Twitter', pct: 9, color: '#3b82f6' },
    { platform: 'Direct Export', pct: 7, color: '#6b7280' },
  ];
}

/**
 * Supabase RPC: get_subscription_funnel()
 * SQL:
 *   SELECT
 *     COUNT(*) FILTER (WHERE subscription_tier IS NULL OR subscription_tier = 'free') AS free_users,
 *     COUNT(*) FILTER (WHERE subscription_status = 'trialing') AS trial_users,
 *     COUNT(*) FILTER (WHERE subscription_tier = 'pro' AND subscription_status = 'active') AS pro_users,
 *     COUNT(*) FILTER (WHERE subscription_status = 'canceled') AS churned_users
 *   FROM users;
 */
function generateFunnelData() {
  return [
    { stage: 'Free Users', value: 18420, color: '#6b7280', pct: 100 },
    { stage: 'Trial Started', value: 4860, color: '#f97316', pct: 26.4 },
    { stage: 'Pro Subscribers', value: 1724, color: '#22c55e', pct: 9.4 },
    { stage: 'Churned', value: 312, color: '#ef4444', pct: 1.7 },
  ];
}

// ─── SVG Chart Components ────────────────────────────────────────

interface ChartPoint { label: string; value: number }

function LineChart({
  data,
  color,
  height = 200,
  showArea = true,
}: {
  data: ChartPoint[];
  color: string;
  height?: number;
  showArea?: boolean;
}) {
  if (!data.length) return null;

  const padding = { top: 20, right: 12, bottom: 32, left: 50 };
  const w = 600;
  const h = height;
  const chartW = w - padding.left - padding.right;
  const chartH = h - padding.top - padding.bottom;

  const maxVal = Math.max(...data.map((d) => d.value));
  const minVal = Math.min(...data.map((d) => d.value)) * 0.85;
  const range = maxVal - minVal || 1;

  const points = data.map((d, i) => ({
    x: padding.left + (i / (data.length - 1)) * chartW,
    y: padding.top + chartH - ((d.value - minVal) / range) * chartH,
    ...d,
  }));

  const pathD = points.map((p, i) => `${i === 0 ? 'M' : 'L'}${p.x},${p.y}`).join(' ');
  const areaD = `${pathD} L${points[points.length - 1].x},${padding.top + chartH} L${points[0].x},${padding.top + chartH} Z`;

  // Y-axis ticks
  const yTicks = 5;
  const yTickValues = Array.from({ length: yTicks }, (_, i) =>
    Math.round(minVal + (range * i) / (yTicks - 1)),
  );

  // X-axis labels (show every Nth)
  const xLabelEvery = Math.max(1, Math.floor(data.length / 7));

  return (
    <svg viewBox={`0 0 ${w} ${h}`} className="w-full" preserveAspectRatio="xMidYMid meet">
      {/* Grid lines */}
      {yTickValues.map((val, i) => {
        const y = padding.top + chartH - ((val - minVal) / range) * chartH;
        return (
          <g key={i}>
            <line x1={padding.left} y1={y} x2={w - padding.right} y2={y} stroke="#374151" strokeWidth="0.5" />
            <text x={padding.left - 8} y={y + 4} textAnchor="end" fill="#6b7280" fontSize="10">
              {val >= 1000 ? `${(val / 1000).toFixed(1)}k` : val}
            </text>
          </g>
        );
      })}

      {/* Area fill */}
      {showArea && <path d={areaD} fill={color} fillOpacity="0.08" />}

      {/* Line */}
      <path d={pathD} fill="none" stroke={color} strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />

      {/* Data points (show dots on hover via CSS) */}
      {points.map((p, i) => (
        <g key={i}>
          <circle cx={p.x} cy={p.y} r="3" fill={color} opacity="0" className="hover:opacity-100 transition-opacity">
            <title>{`${p.label}: ${p.value.toLocaleString()}`}</title>
          </circle>
          {/* X-axis labels */}
          {i % xLabelEvery === 0 && (
            <text x={p.x} y={h - 6} textAnchor="middle" fill="#6b7280" fontSize="9">
              {p.label}
            </text>
          )}
        </g>
      ))}

      {/* Endpoint dot */}
      <circle cx={points[points.length - 1].x} cy={points[points.length - 1].y} r="4" fill={color} />
      <circle cx={points[points.length - 1].x} cy={points[points.length - 1].y} r="7" fill={color} fillOpacity="0.25" />
    </svg>
  );
}

function BarChart({ data, color, height = 200 }: { data: ChartPoint[]; color: string; height?: number }) {
  if (!data.length) return null;

  const padding = { top: 16, right: 12, bottom: 32, left: 50 };
  const w = 600;
  const h = height;
  const chartW = w - padding.left - padding.right;
  const chartH = h - padding.top - padding.bottom;

  const maxVal = Math.max(...data.map((d) => d.value)) * 1.1;
  const barW = chartW / data.length;
  const barPad = barW * 0.2;

  // Y-axis ticks
  const yTicks = 5;
  const yTickValues = Array.from({ length: yTicks }, (_, i) => Math.round((maxVal * i) / (yTicks - 1)));

  return (
    <svg viewBox={`0 0 ${w} ${h}`} className="w-full" preserveAspectRatio="xMidYMid meet">
      {/* Grid */}
      {yTickValues.map((val, i) => {
        const y = padding.top + chartH - (val / maxVal) * chartH;
        return (
          <g key={i}>
            <line x1={padding.left} y1={y} x2={w - padding.right} y2={y} stroke="#374151" strokeWidth="0.5" />
            <text x={padding.left - 8} y={y + 4} textAnchor="end" fill="#6b7280" fontSize="10">
              {val}
            </text>
          </g>
        );
      })}

      {/* Bars */}
      {data.map((d, i) => {
        const barH = (d.value / maxVal) * chartH;
        const x = padding.left + i * barW + barPad;
        const y = padding.top + chartH - barH;
        return (
          <g key={i}>
            <rect x={x} y={y} width={barW - barPad * 2} height={barH} rx="3" fill={color} fillOpacity="0.8">
              <title>{`${d.label}: ${d.value.toLocaleString()}`}</title>
            </rect>
            <text x={x + (barW - barPad * 2) / 2} y={h - 6} textAnchor="middle" fill="#6b7280" fontSize="9">
              {d.label}
            </text>
          </g>
        );
      })}
    </svg>
  );
}

function DonutChart({
  data,
  size = 180,
}: {
  data: { platform: string; pct: number; color: string }[];
  size?: number;
}) {
  const r = size / 2 - 10;
  const cx = size / 2;
  const cy = size / 2;
  const strokeW = 28;
  const innerR = r - strokeW / 2;
  const circumference = 2 * Math.PI * innerR;

  let accOffset = 0;

  return (
    <div className="flex items-center gap-6">
      <svg width={size} height={size} className="shrink-0">
        {data.map((d, i) => {
          const segLen = (d.pct / 100) * circumference;
          const gap = 4;
          const offset = accOffset;
          accOffset += segLen + gap;
          return (
            <circle
              key={i}
              cx={cx}
              cy={cy}
              r={innerR}
              fill="none"
              stroke={d.color}
              strokeWidth={strokeW}
              strokeDasharray={`${segLen - gap} ${circumference}`}
              strokeDashoffset={-offset}
              strokeLinecap="round"
              transform={`rotate(-90 ${cx} ${cy})`}
            >
              <title>{`${d.platform}: ${d.pct}%`}</title>
            </circle>
          );
        })}
        <text x={cx} y={cy - 6} textAnchor="middle" fill="white" fontSize="18" fontWeight="bold">
          {data.reduce((a, d) => a + d.pct, 0)}%
        </text>
        <text x={cx} y={cy + 12} textAnchor="middle" fill="#9ca3af" fontSize="10">
          published
        </text>
      </svg>
      <div className="space-y-2 text-sm">
        {data.map((d) => (
          <div key={d.platform} className="flex items-center gap-2">
            <span className="w-3 h-3 rounded-full shrink-0" style={{ backgroundColor: d.color }} />
            <span className="text-gray-300">{d.platform}</span>
            <span className="text-gray-500 ml-auto font-mono">{d.pct}%</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function FunnelChart({ data }: { data: { stage: string; value: number; color: string; pct: number }[] }) {
  const maxVal = data[0].value;
  return (
    <div className="space-y-3">
      {data.map((d) => {
        const widthPct = Math.max(8, (d.value / maxVal) * 100);
        return (
          <div key={d.stage}>
            <div className="flex items-center justify-between text-sm mb-1">
              <span className="text-gray-300">{d.stage}</span>
              <span className="font-mono text-gray-400">
                {d.value.toLocaleString()}
                <span className="text-gray-600 ml-1.5">({d.pct}%)</span>
              </span>
            </div>
            <div className="h-7 bg-gray-800 rounded-lg overflow-hidden">
              <div
                className="h-full rounded-lg transition-all duration-700 ease-out"
                style={{ width: `${widthPct}%`, backgroundColor: d.color }}
              />
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ─── KPI Card ────────────────────────────────────────────────────

function KPICard({
  label,
  value,
  icon,
  color,
  change,
  subtext,
}: {
  label: string;
  value: string;
  icon: string;
  color: string;
  change?: { value: string; positive: boolean };
  subtext?: string;
}) {
  return (
    <div className="stat-card group">
      <div className="flex items-center justify-between mb-2">
        <span className="text-gray-500 text-sm">{label}</span>
        <span className="text-xl opacity-60 group-hover:opacity-100 transition">{icon}</span>
      </div>
      <p className={`text-2xl font-bold ${color}`}>{value}</p>
      <div className="flex items-center gap-2 mt-1">
        {change && (
          <span className={`text-xs font-medium ${change.positive ? 'text-green-400' : 'text-red-400'}`}>
            {change.positive ? '▲' : '▼'} {change.value}
          </span>
        )}
        {subtext && <span className="text-xs text-gray-600">{subtext}</span>}
      </div>
    </div>
  );
}

// ─── Live Indicator ──────────────────────────────────────────────

function LiveIndicator({ secondsAgo }: { secondsAgo: number }) {
  return (
    <div className="flex items-center gap-2 text-sm text-gray-400">
      <span className="relative flex h-2.5 w-2.5">
        <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-green-400 opacity-75" />
        <span className="relative inline-flex rounded-full h-2.5 w-2.5 bg-green-500" />
      </span>
      <span>
        Live — updated {secondsAgo < 5 ? 'just now' : `${secondsAgo}s ago`}
      </span>
    </div>
  );
}

// ─── Main Analytics Page ─────────────────────────────────────────

export default function AnalyticsPage() {
  const [lastUpdated, setLastUpdated] = useState(0);
  const [loading, setLoading] = useState(true);

  // ── data state ──
  const [dauData, setDauData] = useState<ChartPoint[]>([]);
  const [videosData, setVideosData] = useState<ChartPoint[]>([]);
  const [revenueData, setRevenueData] = useState<ChartPoint[]>([]);
  const [creators, setCreators] = useState<ReturnType<typeof generateTopCreators>>([]);
  const [platformData, setPlatformData] = useState<ReturnType<typeof generatePlatformData>>([]);
  const [funnelData, setFunnelData] = useState<ReturnType<typeof generateFunnelData>>([]);

  // ── KPI state ──
  const [kpis, setKpis] = useState({
    dau: 0,
    videosToday: 0,
    videosAllTime: 0,
    monthlyRevenue: 0,
    totalUsers: 0,
    proSubscribers: 0,
    avgSession: '0m 0s',
  });

  const fetchAll = useCallback(async () => {
    setLoading(true);

    // In production, each of these would be a supabase.rpc() call:
    // const { data: dauRows } = await supabase.rpc('get_daily_active_users', { days: 30 });
    const dau = generateDAUData(30);
    const videos = generateVideosData(14);
    const revenue = generateRevenueData(12);
    const topCreators = generateTopCreators();
    const platforms = generatePlatformData();
    const funnel = generateFunnelData();

    setDauData(dau);
    setVideosData(videos);
    setRevenueData(revenue);
    setCreators(topCreators);
    setPlatformData(platforms);
    setFunnelData(funnel);

    const latestDAU = dau[dau.length - 1]?.value ?? 0;
    const todayVideos = videos[videos.length - 1]?.value ?? 0;
    const totalVids = videos.reduce((a, v) => a + v.value, 0) * 14; // extrapolate
    const latestRevenue = revenue[revenue.length - 1]?.value ?? 0;

    setKpis({
      dau: latestDAU,
      videosToday: todayVideos,
      videosAllTime: totalVids,
      monthlyRevenue: latestRevenue,
      totalUsers: funnel[0].value + funnel[2].value + funnel[3].value,
      proSubscribers: funnel[2].value,
      avgSession: '4m 32s',
    });

    setLoading(false);
    setLastUpdated(0);
  }, []);

  // Auto-refresh every 30s
  useEffect(() => {
    fetchAll();
    const refreshInterval = setInterval(fetchAll, 30_000);
    return () => clearInterval(refreshInterval);
  }, [fetchAll]);

  // Tick the "last updated" counter
  useEffect(() => {
    const ticker = setInterval(() => setLastUpdated((s) => s + 1), 1000);
    return () => clearInterval(ticker);
  }, []);

  // Memoize derived calcs
  const dauChange = useMemo(() => {
    if (dauData.length < 8) return { value: '0%', positive: true };
    const recent7 = dauData.slice(-7).reduce((a, d) => a + d.value, 0) / 7;
    const prev7 = dauData.slice(-14, -7).reduce((a, d) => a + d.value, 0) / 7;
    const pctChange = prev7 > 0 ? (((recent7 - prev7) / prev7) * 100).toFixed(1) : '0';
    return { value: `${pctChange}% vs prev week`, positive: Number(pctChange) >= 0 };
  }, [dauData]);

  const revenueChange = useMemo(() => {
    if (revenueData.length < 2) return { value: '0%', positive: true };
    const curr = revenueData[revenueData.length - 1].value;
    const prev = revenueData[revenueData.length - 2].value;
    const pctChange = prev > 0 ? (((curr - prev) / prev) * 100).toFixed(1) : '0';
    return { value: `${pctChange}% vs last month`, positive: Number(pctChange) >= 0 };
  }, [revenueData]);

  if (loading && !dauData.length) {
    return (
      <div className="p-6 space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold">Analytics</h1>
            <p className="text-sm text-gray-500">Loading real-time metrics…</p>
          </div>
        </div>
        <div className="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-4">
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className="stat-card animate-pulse">
              <div className="h-3 bg-gray-800 rounded w-16 mb-3" />
              <div className="h-7 bg-gray-800 rounded w-20" />
            </div>
          ))}
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {Array.from({ length: 4 }).map((_, i) => (
            <div key={i} className="bg-gray-900 rounded-xl border border-gray-800 p-5 h-64 animate-pulse" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="p-6 space-y-6 max-w-[1600px]">
      {/* ── Header ── */}
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div>
          <h1 className="text-2xl font-bold">Analytics</h1>
          <p className="text-sm text-gray-500">Real-time platform performance</p>
        </div>
        <div className="flex items-center gap-4">
          <LiveIndicator secondsAgo={lastUpdated} />
          <button onClick={fetchAll} className="btn-ghost text-sm" disabled={loading}>
            {loading ? 'Refreshing…' : '↻ Refresh'}
          </button>
        </div>
      </div>

      {/* ── KPI Cards ── */}
      <div className="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-4">
        <KPICard
          label="Daily Active Users"
          value={kpis.dau.toLocaleString()}
          icon="👤"
          color="text-orange-400"
          change={dauChange}
        />
        <KPICard
          label="Videos Published"
          value={kpis.videosToday.toLocaleString()}
          icon="🎬"
          color="text-cyan-400"
          subtext={`${kpis.videosAllTime.toLocaleString()} all-time`}
        />
        <KPICard
          label="Monthly Revenue"
          value={`$${kpis.monthlyRevenue.toLocaleString()}`}
          icon="💰"
          color="text-green-400"
          change={revenueChange}
        />
        <KPICard
          label="Registered Users"
          value={kpis.totalUsers.toLocaleString()}
          icon="👥"
          color="text-blue-400"
          change={{ value: '12.3% MoM', positive: true }}
        />
        <KPICard
          label="Pro Subscribers"
          value={kpis.proSubscribers.toLocaleString()}
          icon="⭐"
          color="text-yellow-400"
          change={{ value: '8.1% MoM', positive: true }}
        />
        <KPICard
          label="Avg Session"
          value={kpis.avgSession}
          icon="⏱"
          color="text-purple-400"
          change={{ value: '0:18', positive: true }}
          subtext="vs last week"
        />
      </div>

      {/* ── Charts Grid ── */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* DAU Line Chart */}
        <div className="bg-gray-900 rounded-xl border border-gray-800 p-5">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h2 className="font-semibold">Daily Active Users</h2>
              <p className="text-xs text-gray-500">Last 30 days</p>
            </div>
            <span className="text-xs bg-orange-900/30 text-orange-400 px-2 py-1 rounded-full">DAU</span>
          </div>
          <LineChart data={dauData} color="#f97316" height={220} />
        </div>

        {/* Videos Published Bar Chart */}
        <div className="bg-gray-900 rounded-xl border border-gray-800 p-5">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h2 className="font-semibold">Videos Published</h2>
              <p className="text-xs text-gray-500">Last 14 days</p>
            </div>
            <span className="text-xs bg-cyan-900/30 text-cyan-400 px-2 py-1 rounded-full">Daily</span>
          </div>
          <BarChart data={videosData} color="#06b6d4" height={220} />
        </div>

        {/* Revenue Line Chart */}
        <div className="bg-gray-900 rounded-xl border border-gray-800 p-5">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h2 className="font-semibold">Monthly Revenue</h2>
              <p className="text-xs text-gray-500">Last 12 months</p>
            </div>
            <span className="text-xs bg-green-900/30 text-green-400 px-2 py-1 rounded-full">MRR</span>
          </div>
          <LineChart data={revenueData} color="#22c55e" height={220} />
        </div>

        {/* Platform Distribution */}
        <div className="bg-gray-900 rounded-xl border border-gray-800 p-5">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h2 className="font-semibold">Platform Distribution</h2>
              <p className="text-xs text-gray-500">Publish target breakdown</p>
            </div>
          </div>
          <div className="flex justify-center py-4">
            <DonutChart data={platformData} size={180} />
          </div>
        </div>
      </div>

      {/* ── Full-width sections ── */}
      <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
        {/* Top Creators Table — 3 cols */}
        <div className="lg:col-span-3 bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
          <div className="px-5 py-4 border-b border-gray-800 flex items-center justify-between">
            <div>
              <h2 className="font-semibold">Top Creators</h2>
              <p className="text-xs text-gray-500">By total views, all time</p>
            </div>
            <span className="text-xs text-gray-600">Top 10</span>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-gray-500 text-xs uppercase border-b border-gray-800">
                  <th className="text-left px-5 py-3 w-10">#</th>
                  <th className="text-left px-5 py-3">Creator</th>
                  <th className="text-right px-5 py-3">Videos</th>
                  <th className="text-right px-5 py-3">Views</th>
                  <th className="text-right px-5 py-3">Likes</th>
                </tr>
              </thead>
              <tbody>
                {creators.map((c) => (
                  <tr key={c.rank} className="table-row">
                    <td className="px-5 py-2.5 text-gray-600 font-mono">{c.rank}</td>
                    <td className="px-5 py-2.5">
                      <div className="flex items-center gap-2.5">
                        <div className="w-7 h-7 rounded-full bg-gray-800 flex items-center justify-center text-xs font-bold text-gray-400">
                          {c.username.charAt(0).toUpperCase()}
                        </div>
                        <span className="font-medium">{c.username}</span>
                      </div>
                    </td>
                    <td className="px-5 py-2.5 text-right font-mono text-gray-300">{c.videos}</td>
                    <td className="px-5 py-2.5 text-right font-mono text-cyan-400">
                      {c.views >= 1000 ? `${(c.views / 1000).toFixed(1)}K` : c.views}
                    </td>
                    <td className="px-5 py-2.5 text-right font-mono text-pink-400">
                      {c.likes >= 1000 ? `${(c.likes / 1000).toFixed(1)}K` : c.likes}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        {/* Subscription Funnel — 2 cols */}
        <div className="lg:col-span-2 bg-gray-900 rounded-xl border border-gray-800 p-5">
          <div className="mb-4">
            <h2 className="font-semibold">Subscription Funnel</h2>
            <p className="text-xs text-gray-500">Conversion from free → paid</p>
          </div>
          <FunnelChart data={funnelData} />
          <div className="mt-5 pt-4 border-t border-gray-800 grid grid-cols-2 gap-3 text-center">
            <div>
              <p className="text-xs text-gray-500">Trial → Pro</p>
              <p className="text-lg font-bold text-green-400">35.5%</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Monthly Churn</p>
              <p className="text-lg font-bold text-red-400">1.7%</p>
            </div>
          </div>
        </div>
      </div>

      {/* ── Footer ── */}
      <div className="text-center text-xs text-gray-600 pb-4">
        Data refreshes automatically every 30 seconds · StickDeath ∞ Admin Analytics
      </div>
    </div>
  );
}
