import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:openrouter_sdk/openrouter_sdk.dart';
import 'package:notesmith/system_prompt.dart';
import 'package:uuid/uuid.dart';

class Settings {
	final String token;
	final String owner;
	final String repo;
	final String branch;
	final String folder;
	final OpenRouter openRouterClient;

	Settings._({
		required this.token,
		required this.owner,
		required this.repo,
		required this.branch,
		required this.folder,
		required this.openRouterClient,
	});

	factory Settings.fromEnv() {
		final env = DotEnv()..load();

		final token = env["TOKEN"];
		final owner = env["OWNER"];
		final repo = env["REPO"];
		final openRouterKey = env['OPENROUTER_KEY'];
		final branch = env["BRANCH"] ?? "main";
		final folder = env["FOLDER"] ?? "AI_Formatter";

		if (token == null ||
				token.isEmpty ||
				owner == null ||
				owner.isEmpty ||
				repo == null ||
				repo.isEmpty ||
				openRouterKey == null ||
				openRouterKey.isEmpty) {
			print(
				"Error: Missing required environment variables (TOKEN, OWNER, REPO, OPENROUTER_KEY).",
			);
			exit(1);
		}

		final openRouterClient = OpenRouter(apiKey: openRouterKey);

		return Settings._(
			token: token,
			owner: owner,
			repo: repo,
			branch: branch,
			folder: folder,
			openRouterClient: openRouterClient,
		);
	}
}

Future<List<dynamic>> fetchNotes(Settings settings) async {
	final Uri url = Uri.parse(
		'https://api.github.com/repos/${settings.owner}/${settings.repo}/git/trees/${settings.branch}?recursive=1',
	);

	final Map<String, String> headers = {
		'Authorization': 'Bearer ${settings.token}',
		'Accept': 'application/vnd.github+json',
		'X-GitHub-Api-Version': '2022-11-28',
	};

	final response = await http.get(url, headers: headers);
	if (response.statusCode == 200) {
		final Map<String, dynamic> data = jsonDecode(response.body);
		final List<dynamic> tree = data['tree'] ?? [];
		return tree.where((entry) {
			final path = entry['path'].toString();
			return path.startsWith('${settings.folder}/input/') &&
					!path.endsWith('_ignore.md') &&
					entry['type'] != 'tree';
		}).toList();
	}
	return [];
}

Future<String> fetchNote(String noteUrl, Settings settings) async {
	final Uri url = Uri.parse(noteUrl);

	final Map<String, String> headers = {
		'Authorization': 'Bearer ${settings.token}',
		'Accept': 'application/vnd.github+json',
		'X-GitHub-Api-Version': '2022-11-28',
	};

	final response = await http.get(url, headers: headers);
	if (response.statusCode == 200) {
		final Map<String, dynamic> data = jsonDecode(response.body);
		final List<int> decodedBytes = base64.decode(
			data['content'].replaceAll(RegExp(r'\s'), ''),
		);
		return utf8.decode(decodedBytes);
	}
	return "";
}

Future<bool> createFile(
	Settings settings,
	String path,
	String content, {
	bool noPrefix = false,
}) async {
	final filePath = noPrefix ? path : '${settings.folder}/output/$path';
	final Uri url = Uri.parse(
		'https://api.github.com/repos/${settings.owner}/${settings.repo}/contents/$filePath',
	);

	final Map<String, String> headers = {
		'Authorization': 'Bearer ${settings.token}',
		'Accept': 'application/vnd.github+json',
		'X-GitHub-Api-Version': '2022-11-28',
		'Content-Type': 'application/json',
	};

	final base64Content = base64.encode(utf8.encode(content));

	final Map<String, dynamic> body = {
		'message': "created file.",
		'content': base64Content,
	};

	final response = await http.put(
		url,
		headers: headers,
		body: jsonEncode(body),
	);

	return response.statusCode == 201;
}

Future<bool> deleteFile(Settings settings, String path) async {
	final filePath = path.startsWith('${settings.folder}/')
			? path
			: '${settings.folder}/$path';

	final Uri url = Uri.parse(
		'https://api.github.com/repos/${settings.owner}/${settings.repo}/contents/$filePath?ref=${settings.branch}',
	);

	final Map<String, String> headers = {
		'Authorization': 'Bearer ${settings.token}',
		'Accept': 'application/vnd.github+json',
		'X-GitHub-Api-Version': '2022-11-28',
		'Content-Type': 'application/json',
	};

	try {
		// 1. Krok: Získání SHA souboru
		final getResponse = await http.get(url, headers: headers);
		if (getResponse.statusCode != 200) {
			print("Chyba při zjišťování SHA souboru: ${getResponse.statusCode}");
			return false;
		}

		final Map<String, dynamic> fileData = jsonDecode(getResponse.body);
		final String sha = fileData["sha"];

		// 2. Krok: Smazání souboru
		final Map<String, dynamic> body = {
			'message': 'deleted file',
			'sha': sha,
			'branch': settings.branch,
		};

		final deleteResponse = await http.delete(
			url,
			headers: headers,
			body: jsonEncode(body),
		);

		return deleteResponse.statusCode == 200;
	} catch (e) {
		print("Chyba při mazání souboru: $e");
		return false;
	}
}

Future<void> runOrchestrator(Settings settings, List<dynamic> notes) async {
	final writeTool = FunctionTool(
		name: 'write_content',
		description: 'write content into file',
		parameters: {
			'type': 'object',
			'properties': {
				'path': {
					'type': 'string',
					'description': "path of the file, must ends with .md for markdown or .canvas for canvas eg. notes/schema.md",
				},
				'content': {'type': 'string', "description": "Content of the file"},
			},
			'required': ['path', "content"],
		},
	);

	final readTool = FunctionTool(
		name: 'read_content',
		description: 'read content of the file',
		parameters: {
			'type': 'object',
			'properties': {
				'file_url': {'type': 'string', 'description': "full url of the file"},
			},
			'required': ["file_url"],
		},
	);

	final List<FunctionTool> tools = [writeTool, readTool];

	final notesJson = json.encode(notes);

	var running = true;
	final messages = <ChatMessage>[
		SystemMessage.fromText(content: systemPrompt),
		UserMessage.text(
			content:
					'Zde je seznam dostupných poznámek v JSONu:\n$notesJson\n\nPřečti jejich obsah pomocí `read_content` a ulož přeformátované .md verze přes `write_content`. Nezapomeň zachovat strukturu podsložek (např. z "AI_Formatter/input/Inf/Sítě.md" zapiš "Inf/Sítě.md") a všechny vstupy (včetně .canvas) převeď na vyšperkovaný Obsidian Markdown (.md) s využitím calloutů a zvýraznění ==textu==.',
		),
	];

	while (running) {
		final ChatResponse response = await settings.openRouterClient.chat.send(
			messages: messages,
			model: 'google/gemini-3.1-flash-lite',
			tools: tools,
		);
		final AssistantMessage message = response.choices.last.message;
		messages.add(message);
		if (message.toolCalls.isNotEmpty) {
			for (final toolCall in message.toolCalls) {
				final functionName = toolCall.functionName;
				final arguments = toolCall.arguments;

				print('Model invoked tool: $functionName with args: $arguments');

				String toolResult = "";
				if (functionName == "write_content") {
					final bool success = await createFile(
						settings,
						arguments["path"],
						arguments["content"],
					);

					toolResult = json.encode({"write success": success});
				} else if (functionName == "read_content") {
					final String content = await fetchNote(
						arguments["file_url"],
						settings,
					);

					toolResult = json.encode({"content": content});
				} else {
					toolResult = json.encode({"Error": "Tool not found"});
				}

				messages.add(
					ToolMessage.text(content: toolResult, toolCallId: toolCall.id),
				);
			}
		} else {
			running = false;
			print(message.content);
		}
	}
}

Future<void> backupNotes(Settings settings, List<dynamic> notes) async {
	print('Backup started.');
	final backupId = const Uuid().v4().replaceAll('-', '');
	for (final note in notes) {
		final noteText = await fetchNote(note['url'], settings);
		final path = note['path'].toString().replaceAll(
			'input',
			'backup/$backupId',
		);
		await createFile(settings, path, noteText, noPrefix: true);
		await deleteFile(settings, note['path']);
	}
}

Future<void> startInfiniteLoop(Settings settings) async {
	while (true) {
		try {
			final notes = await fetchNotes(settings);

			if (notes.isNotEmpty) {
				print('Files to process detected.');
				try {
					await runOrchestrator(settings, notes);
				} catch (e) {
					print("ERROR: $e");
				}
				try {
					await backupNotes(settings, notes);
				} catch (e) {
					print("ERROR: $e");
				}
			} else {
				print("no files to process skipping");
			}
		} catch (e) {
			print("ERROR: $e");
		}

		await Future.delayed(const Duration(minutes: 5));
	}
}

Future<void> main(List<String> arguments) async {
	final settings = Settings.fromEnv();
	print('Polling started.');
	await startInfiniteLoop(settings);
}
