import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { openStore, PALETTE } from './db.mjs';

const ROOT = resolve(fileURLToPath(new URL('.', import.meta.url)), '..');

const pad = (n) => String(n).padStart(2, '0');
const iso = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:00`;
const dateOnly = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const at = (base, dayOffset, hour, minute = 0) => {
  const d = new Date(base);
  d.setDate(d.getDate() + dayOffset);
  d.setHours(hour, minute, 0, 0);
  return d;
};

export function seed(store, { now = new Date() } = {}) {
  const projects = [
    { name: '产品官网改版', color: PALETTE[0], description: '把官网信息架构重做一遍，重点提升转化路径。' },
    { name: '客户交付 · 星河', color: PALETTE[2], description: 'Q4 交付里程碑：数据看板 + 权限体系。' },
    { name: '个人成长', color: PALETTE[3], description: '阅读、写作与每周复盘。' },
  ].map((p) => store.createProject(p));

  const tasks = [
    // 官网改版
    { project: 0, title: '梳理现有页面清单与访问数据', status: 'done', priority: 'high', day: -3, hour: 10, minutes: 90, est: 90,
      notes: '导出近 90 天访问数据，标记高流量页面。', subs: [{ title: '导出 GA 数据', done: true }, { title: '整理页面清单', done: true }] },
    { project: 0, title: '信息架构草案评审', status: 'doing', priority: 'urgent', day: 0, hour: 9.5, minutes: 60, est: 60,
      notes: '拉上设计和市场一起过一遍导航层级。', subs: [{ title: '准备评审材料', done: true }, { title: '发出会议邀请', done: false }] },
    { project: 0, title: '首页视觉稿 v2', status: 'doing', priority: 'high', day: 1, hour: 14, minutes: 120, est: 120,
      notes: '重点修改首屏 hero 与信任背书模块。' },
    { project: 0, title: '组件库与设计规范对齐', status: 'todo', priority: 'normal', day: 2, hour: 10, minutes: 90, est: 90 },
    { project: 0, title: '落地页文案终稿', status: 'todo', priority: 'normal', due: 4, est: 45 },
    { project: 0, title: '可用性测试 5 人', status: 'todo', priority: 'high', due: 7, est: 180,
      notes: '准备任务脚本，记录完成率与卡点。' },
    // 客户交付
    { project: 1, title: '权限模型技术方案', status: 'doing', priority: 'urgent', day: 0, hour: 14, minutes: 120, est: 120,
      notes: 'RBAC + 数据行级权限，先给出最小可用方案。', subs: [{ title: '画权限矩阵', done: true }, { title: '评审接口设计', done: false }] },
    { project: 1, title: '日报：数据看板联调', status: 'todo', priority: 'high', day: 1, hour: 9, minutes: 60, est: 60 },
    { project: 1, title: '修复导出 Excel 乱码', status: 'todo', priority: 'urgent', due: -1, est: 45,
      notes: '客户反馈 Windows 下中文表头乱码，需带 BOM。' },
    { project: 1, title: '准备周会演示环境', status: 'todo', priority: 'normal', day: 3, hour: 16, minutes: 45, est: 45 },
    { project: 1, title: '交付验收清单', status: 'todo', priority: 'normal', due: 10, est: 60 },
    // 个人成长
    { project: 2, title: '读《深度工作》第 3 章', status: 'todo', priority: 'low', day: 0, hour: 21, minutes: 45, est: 45 },
    { project: 2, title: '周复盘与下周计划', status: 'todo', priority: 'normal', day: 2, hour: 20, minutes: 60, est: 60 },
    { project: 2, title: '写一篇关于日历化时间管理的文章', status: 'todo', priority: 'low', due: 6, est: 120 },
    { project: null, title: '整理收件箱，清空待办', status: 'todo', priority: 'low', day: 5, hour: 11, minutes: 30, est: 30 },
  ];

  const created = [];
  for (const t of tasks) {
    const start = t.day === undefined ? null : iso(at(now, t.day, Math.floor(t.hour), Math.round((t.hour % 1) * 60)));
    const end = start ? iso(new Date(new Date(start).getTime() + (t.minutes ?? t.est ?? 60) * 60000)) : null;
    created.push(store.createTask({
      projectId: t.project === null || t.project === undefined ? null : projects[t.project].id,
      title: t.title,
      notes: t.notes ?? '',
      status: t.status ?? 'todo',
      priority: t.priority ?? 'normal',
      estimateMin: t.est ?? null,
      dueDate: t.due === undefined ? null : dateOnly(at(now, t.due, 0)),
      startAt: start,
      endAt: end,
      subtasks: t.subs ?? [],
    }));
  }

  // Completed focus sessions across the last 6 days for the stats view.
  const sessions = [
    [-6, 0, 9, 25], [-6, 1, 14, 50], [-5, 0, 10, 25], [-5, 0, 15, 75],
    [-4, 1, 9, 50], [-4, 2, 20, 25], [-3, 0, 11, 25], [-3, 1, 13, 90],
    [-2, 0, 9, 45], [-2, 2, 21, 25], [-1, 1, 10, 60], [-1, 0, 16, 30],
    [0, 1, 8, 40], [0, 0, 10, 25],
  ];
  for (const [dayOffset, taskIndex, hour, minutes] of sessions) {
    const started = at(now, dayOffset, hour, 0);
    const ended = new Date(started.getTime() + minutes * 60000);
    store.createEntry({
      taskId: created[taskIndex]?.id ?? null,
      startedAt: started.toISOString(),
      endedAt: ended.toISOString(),
      minutes,
      note: minutes >= 45 ? '深度专注' : '',
    });
  }

  store.updateSettings({ weekStart: 1, dayStartHour: 7, dayEndHour: 23, dailyGoalMinutes: 240 });
  return { projects: projects.length, tasks: created.length, entries: sessions.length };
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const dbFile = process.env.DB_FILE || join(ROOT, 'data', 'timeflow.db');
  const store = openStore(dbFile);
  const counts = seed(store);
  store.close();
  console.log(`示例数据已写入 ${dbFile}`, counts);
}
