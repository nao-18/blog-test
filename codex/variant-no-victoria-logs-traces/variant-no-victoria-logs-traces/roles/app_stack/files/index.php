<?php
declare(strict_types=1);

header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header("Content-Security-Policy: default-src 'self'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
header('Cache-Control: no-store');

function escape(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function input(array $source, string $key): string
{
    return isset($source[$key]) && is_string($source[$key]) ? $source[$key] : '';
}

function taskId(string $value): int
{
    $id = filter_var($value, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]);
    if ($id === false) {
        throw new InvalidArgumentException('タスクIDが正しくありません。');
    }
    return $id;
}

$health = input($_GET, 'health') === '1';
try {
    $config = require (getenv('TODO_CONFIG') ?: '/etc/middleware/todo.php');
    $db = new PDO(
        sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $config['host'], $config['port'], $config['database']),
        $config['user'],
        $config['password'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES => false,
         PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_TIMEOUT => 5]
    );
    $db->exec("SET time_zone = '+00:00'");
    if ($health) {
        $db->query('SELECT id FROM tasks LIMIT 1');
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(['status' => 'ok']);
        exit;
    }
} catch (Throwable $exception) {
    error_log('Todo database connection failed: ' . $exception->getMessage());
    http_response_code(503);
    header('Content-Type: ' . ($health ? 'application/json' : 'text/plain') . '; charset=utf-8');
    echo $health ? '{"status":"error"}' : 'データベースに接続できません。時間をおいて再度お試しください。';
    exit;
}

session_start(['use_strict_mode' => 1, 'cookie_httponly' => true,
    'cookie_samesite' => 'Lax', 'cookie_secure' => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off']);
$_SESSION['csrf'] = $_SESSION['csrf'] ?? bin2hex(random_bytes(32));
$error = '';
$notice = $_SESSION['notice'] ?? '';
unset($_SESSION['notice']);
$edit = null;
$title = '';
$description = '';
$completed = false;
$tasks = [];

try {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        if (!hash_equals($_SESSION['csrf'], input($_POST, 'csrf'))) {
            http_response_code(403);
            throw new InvalidArgumentException('フォームの有効期限が切れました。ページを再読み込みしてください。');
        }
        $action = input($_POST, 'action');
        if (!in_array($action, ['create', 'update', 'delete', 'toggle'], true)) {
            throw new InvalidArgumentException('操作が正しくありません。');
        }
        $id = $action === 'create' ? null : taskId(input($_POST, 'id'));
        if ($id !== null) {
            $statement = $db->prepare('SELECT id FROM tasks WHERE id = ?');
            $statement->execute([$id]);
            if (!$statement->fetch()) {
                http_response_code(404);
                throw new InvalidArgumentException('指定されたタスクは見つかりません。');
            }
        }
        if ($action === 'create' || $action === 'update') {
            $title = trim(input($_POST, 'title'));
            $description = trim(input($_POST, 'description'));
            $completed = input($_POST, 'completed') === '1';
            if ($action === 'update') {
                $edit = ['id' => $id];
            }
            if (!mb_check_encoding($title . $description, 'UTF-8') || $title === '' || mb_strlen($title) > 200 || mb_strlen($description) > 5000) {
                throw new InvalidArgumentException('タイトルは1〜200文字、詳細は5000文字以内で入力してください。');
            }
        }
        if ($action === 'create') {
            $statement = $db->prepare('INSERT INTO tasks (title, description, completed) VALUES (?, ?, ?)');
            $statement->execute([$title, $description, (int) $completed]);
        } elseif ($action === 'update') {
            $statement = $db->prepare('UPDATE tasks SET title = ?, description = ?, completed = ? WHERE id = ?');
            $statement->execute([$title, $description, (int) $completed, $id]);
        } elseif ($action === 'toggle') {
            $statement = $db->prepare('UPDATE tasks SET completed = 1 - completed WHERE id = ?');
            $statement->execute([$id]);
        } else {
            $statement = $db->prepare('DELETE FROM tasks WHERE id = ?');
            $statement->execute([$id]);
        }
        $_SESSION['notice'] = ['create' => 'タスクを追加しました。', 'update' => 'タスクを更新しました。',
            'toggle' => 'タスクの状態を変更しました。', 'delete' => 'タスクを削除しました。'][$action];
        header('Location: /', true, 303);
        exit;
    }
    if (isset($_GET['edit'])) {
        $statement = $db->prepare('SELECT * FROM tasks WHERE id = ?');
        $statement->execute([taskId(input($_GET, 'edit'))]);
        $edit = $statement->fetch();
        if (!$edit) {
            http_response_code(404);
            throw new InvalidArgumentException('指定されたタスクは見つかりません。');
        }
        $title = $edit['title'];
        $description = $edit['description'];
        $completed = (bool) $edit['completed'];
    }
} catch (InvalidArgumentException $exception) {
    if (http_response_code() < 400) {
        http_response_code(422);
    }
    $error = $exception->getMessage();
} catch (PDOException $exception) {
    error_log('Todo write/read failed: ' . $exception->getMessage());
    http_response_code(503);
    $error = 'データを保存・取得できませんでした。時間をおいて再度お試しください。';
}

$filter = input($_GET, 'filter');
$where = ['active' => ' WHERE completed = 0', 'done' => ' WHERE completed = 1'][$filter] ?? '';
try {
    $tasks = $db->query('SELECT * FROM tasks' . $where . ' ORDER BY completed ASC, id DESC')->fetchAll();
    $stats = $db->query('SELECT COUNT(*) AS total, COALESCE(SUM(completed), 0) AS done FROM tasks')->fetch();
} catch (PDOException $exception) {
    error_log('Todo list failed: ' . $exception->getMessage());
    http_response_code(503);
    $error = 'タスク一覧を取得できませんでした。';
    $stats = ['total' => 0, 'done' => 0];
}
header('Content-Type: text/html; charset=utf-8');
?>
<!doctype html>
<html lang="ja">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Todo — タスク管理</title>
    <link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
    <header class="heading"><div><p class="eyebrow">MY WORKSPACE</p><h1>今日のタスク</h1><p>やることを整理して、一つずつ進めましょう。</p></div><span class="summary"><?= (int) $stats['done'] ?> / <?= (int) $stats['total'] ?> 完了</span></header>
    <?php if ($notice): ?><p class="notice" role="status"><?= escape($notice) ?></p><?php endif ?>
    <?php if ($error): ?><p class="error" role="alert"><?= escape($error) ?></p><?php endif ?>
    <div class="layout">
        <section class="panel editor" aria-labelledby="editor-title">
            <h2 id="editor-title"><?= $edit ? 'タスクを編集' : '新しいタスク' ?></h2>
            <form method="post" action="/">
                <input type="hidden" name="csrf" value="<?= escape($_SESSION['csrf']) ?>">
                <input type="hidden" name="action" value="<?= $edit ? 'update' : 'create' ?>">
                <?php if ($edit): ?><input type="hidden" name="id" value="<?= (int) $edit['id'] ?>"><?php endif ?>
                <label for="title">タイトル <span>必須</span></label>
                <input id="title" name="title" maxlength="200" required value="<?= escape($title) ?>" placeholder="例：週次レポートを作成する">
                <label for="description">詳細</label>
                <textarea id="description" name="description" maxlength="5000" rows="6" placeholder="メモや手順を入力してください"><?= escape($description) ?></textarea>
                <label class="checkbox"><input type="checkbox" name="completed" value="1" <?= $completed ? 'checked' : '' ?>>完了済みにする</label>
                <button class="primary" type="submit"><?= $edit ? '変更を保存' : '＋ タスクを追加' ?></button>
                <?php if ($edit): ?><a class="cancel" href="/">編集をキャンセル</a><?php endif ?>
            </form>
        </section>
        <section aria-label="タスク一覧">
            <nav class="filters" aria-label="状態で絞り込み">
                <?php foreach (['' => 'すべて', 'active' => '未完了', 'done' => '完了済み'] as $value => $label): ?>
                    <a href="/?filter=<?= escape($value) ?>" <?= ($filter === $value || ($value === '' && !in_array($filter, ['active', 'done'], true))) ? 'aria-current="page"' : '' ?>><?= $label ?></a>
                <?php endforeach ?>
            </nav>
            <?php if (!$tasks && !$error): ?><div class="panel empty"><h2>タスクはありません</h2><p>新しいタスクを追加して始めましょう。</p></div><?php endif ?>
            <?php foreach ($tasks as $task): ?>
                <article class="panel task <?= $task['completed'] ? 'done' : '' ?>">
                    <div class="task-heading"><h2><?= escape($task['title']) ?></h2><span class="badge"><?= $task['completed'] ? '完了' : '未完了' ?></span></div>
                    <?php if ($task['description'] !== ''): ?><p class="description"><?= escape($task['description']) ?></p><?php endif ?>
                    <p class="timestamp">更新：<?= escape($task['updated_at']) ?> UTC</p>
                    <div class="actions">
                        <form method="post" action="/">
                            <input type="hidden" name="csrf" value="<?= escape($_SESSION['csrf']) ?>">
                            <input type="hidden" name="id" value="<?= (int) $task['id'] ?>">
                            <input type="hidden" name="action" value="toggle">
                            <button type="submit"><?= $task['completed'] ? '未完了に戻す' : '完了にする' ?></button>
                        </form>
                        <a href="/?edit=<?= (int) $task['id'] ?>">編集</a>
                        <details class="delete"><summary>削除</summary>
                            <form method="post" action="/">
                                <p>このタスクを削除しますか？</p>
                                <input type="hidden" name="csrf" value="<?= escape($_SESSION['csrf']) ?>">
                                <input type="hidden" name="id" value="<?= (int) $task['id'] ?>">
                                <input type="hidden" name="action" value="delete">
                                <button class="danger" type="submit">削除する</button>
                            </form>
                        </details>
                    </div>
                </article>
            <?php endforeach ?>
        </section>
    </div>
    <footer>Todo · PHP + MySQL</footer>
</main>
</body>
</html>
