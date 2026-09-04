// Cloudflare Worker для WB Монитора цен.
//
// Зачем он нужен: расписание GitHub Actions (on: schedule) в этом репозитории
// не срабатывало ни разу — за 87 минут ноль прогонов по крону при активном
// workflow. У Cloudflare крон настоящий, поэтому расписание живет здесь,
// а Worker просто просит GitHub запустить проверку — ровно то же самое,
// что нажатие кнопки Run workflow.
//
// Секрет GITHUB_TOKEN задается в настройках Worker, в код не попадает.

const ВЛАДЕЛЕЦ     = "Kochetov-EA";
const РЕПОЗИТОРИЙ  = "wb-monitor";
const ФайлWorkflow = "monitor.yml";
const Ветка        = "main";

async function ЗапуститьПроверку(env) {

  if (!env.GITHUB_TOKEN) {
    console.log("Не задан секрет GITHUB_TOKEN");
    return { ок: false, сообщение: "Не задан секрет GITHUB_TOKEN" };
  }

  const адрес = `https://api.github.com/repos/${ВЛАДЕЛЕЦ}/${РЕПОЗИТОРИЙ}/actions/workflows/${ФайлWorkflow}/dispatches`;

  const ответ = await fetch(адрес, {
    method: "POST",
    headers: {
      "Authorization":        `Bearer ${env.GITHUB_TOKEN}`,
      "Accept":               "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent":           "wb-monitor-worker",
      "Content-Type":         "application/json",
    },
    body: JSON.stringify({ ref: Ветка }),
  });

  // при успехе GitHub отвечает 204 без тела
  if (ответ.status === 204) {
    console.log("Проверка запущена");
    return { ок: true, сообщение: "Проверка запущена" };
  }

  const текст = await ответ.text();
  console.log(`GitHub ответил ${ответ.status}: ${текст}`);

  return { ок: false, сообщение: `GitHub ответил ${ответ.status}: ${текст}` };
}

export default {

  // срабатывает по расписанию из wrangler.toml
  async scheduled(event, env, ctx) {
    ctx.waitUntil(ЗапуститьПроверку(env));
  },

  // адрес Worker открыт всему интернету, поэтому запуск отсюда не делаем —
  // иначе любой желающий смог бы дергать прогоны. Только признак жизни.
  async fetch(request, env) {
    return new Response(
      "WB Монитор: планировщик жив. Запуск идет только по расписанию.\n",
      { headers: { "Content-Type": "text/plain; charset=utf-8" } }
    );
  },
};
