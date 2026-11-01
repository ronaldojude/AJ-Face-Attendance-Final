import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:camera/camera.dart';

void main() => runApp(const AJApp());
const blue = Color(0xFF1261CB);
const bg = Color(0xFFF4F7FC);

class AJApp extends StatelessWidget {
  const AJApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'AJ Face Attendance',
        theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: bg,
            colorScheme: ColorScheme.fromSeed(seedColor: blue),
            fontFamily: 'Roboto'),
        home: const AJHome(),
      );
}

class AJHome extends StatefulWidget {
  const AJHome({super.key});
  @override
  State<AJHome> createState() => _AJHomeState();
}

class _AJHomeState extends State<AJHome> with WidgetsBindingObserver {
  CameraController? camera;
  Timer? scanTimer;
  bool scanning = false;
  bool scanRequestInFlight = false;
  String? lastSuccessfulStudent;
  DateTime? lastSuccessTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) stopScanner();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanTimer?.cancel();
    camera?.dispose();
    super.dispose();
  }

  Future<void> startScanner() async {
    if (scanning) return;
    try {
      final available = await availableCameras();
      if (available.isEmpty) throw Exception('No camera available');
      final selected = available.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => available.first,
      );
      final controller = CameraController(selected, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      if (!mounted || tab != 1) {
        await controller.dispose();
        return;
      }
      setState(() {
        camera = controller;
        scanning = true;
        lastFaceMatched = null;
        scanResult = null;
        message = 'Live scanner started';
      });
      scanTimer =
          Timer.periodic(const Duration(seconds: 3), (_) => scanLiveFrame());
      await scanLiveFrame();
    } catch (e) {
      if (mounted) setState(() => message = 'Camera error: $e');
    }
  }

  Future<void> stopScanner() async {
    scanTimer?.cancel();
    scanTimer = null;
    scanning = false;
    final old = camera;
    camera = null;
    if (mounted) setState(() {});
    // An in-flight capture may still finish; its result is ignored after stopping.
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }
  }

  Future<void> scanLiveFrame() async {
    final controller = camera;
    if (!scanning ||
        scanRequestInFlight ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture) {
      return;
    }
    scanRequestInFlight = true;
    try {
      // Captures a frame INSIDE the embedded camera controller. No external camera app opens.
      final frame = await controller.takePicture();
      final request =
          http.MultipartRequest('POST', Uri.parse('$root/api/scan'));
      request.headers.addAll(headers);
      request.fields['action'] = checkIn ? 'in' : 'out';
      request.files.add(await http.MultipartFile.fromPath('photo', frame.path));
      final response = await http.Response.fromStream(
          await request.send().timeout(const Duration(seconds: 15)));
      if (!scanning || !mounted) return;
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return;
      if (response.statusCode == 422) {
        setState(() {
          lastFaceMatched = false;
          scanResult = null;
          message = '${body['message'] ?? 'Position one face in view'}';
        });
        return;
      }
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
      if (body['success'] != true) {
        setState(() {
          lastFaceMatched = false;
          scanResult = null;
          message = '${body['message'] ?? 'Face not recognized'}';
        });
        return;
      }
      final id = '${body['student']?['id'] ?? ''}';
      final now = DateTime.now();
      if (id.isNotEmpty &&
          id == lastSuccessfulStudent &&
          lastSuccessTime != null &&
          now.difference(lastSuccessTime!).inSeconds < 60) {
        return;
      }
      lastSuccessfulStudent = id;
      lastSuccessTime = now;
      setState(() {
        scanResult = body;
        message = body['attendance_recorded'] == true
            ? 'Attendance marked: ${body['student_name'] ?? id}'
            : 'Face recognized, but attendance NOT recorded by server';
      });
    } catch (e) {
      if (mounted && scanning) setState(() => message = 'Scanner: $e');
    } finally {
      scanRequestInFlight = false;
    }
  }

  int tab = 0;
  String server =
      'http://10.0.2.2:8000'; // Android emulator; replace with LAN IP or HTTPS cloud URL.
  String username = 'admin';
  String password = '';
  String registerId = '', registerName = '', registerTeam = '';
  String? enrollmentId;
  int enrollmentSamples = 0;
  bool checkIn = true, busy = false;
  Map<String, dynamic>? dashboard;
  Map<String, dynamic>? scanResult;
  bool? lastFaceMatched;
  String message = 'Connect to backend in Settings';

  String get root => server.trim().replaceAll(RegExp(r'/+$'), '');
  Map<String, String> get headers => {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}'
      };

  Future<void> refresh() async {
    setState(() {
      busy = true;
      message = 'Loading attendance...';
    });
    try {
      final response = await http
          .get(Uri.parse('$root/api/dashboard'), headers: headers)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        throw Exception('Unexpected dashboard response');
      }
      if (!mounted) return;
      setState(() {
        dashboard = body;
        message = 'Connected';
      });
    } catch (e) {
      if (mounted) setState(() => message = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget card(Widget child, {EdgeInsets padding = const EdgeInsets.all(16)}) =>
      Container(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(18)),
          child: child);

  Widget heading(String text, String sub) => Column(children: [
        const SizedBox(height: 14),
        Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: blue, fontSize: 27, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(sub,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 13)),
        const SizedBox(height: 18),
      ]);

  Widget stat(String name, String value, IconData icon, Color color) =>
      Container(
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 8),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: color, size: 21),
              const SizedBox(width: 6),
              Flexible(
                  child: Text(name,
                      style: const TextStyle(fontSize: 12),
                      textAlign: TextAlign.center)),
            ]),
            const SizedBox(height: 9),
            Text(value,
                style: const TextStyle(
                    color: blue, fontSize: 30, fontWeight: FontWeight.bold))
          ]));

  Widget dashboardPage() {
    final counts =
        dashboard?['counts'] is Map ? dashboard!['counts'] as Map : {};
    int count(String k) => (counts[k] as num?)?.toInt() ?? 0;
    final total = (dashboard?['total'] as num?)?.toInt() ?? 0;
    final present = count('Present');
    final half = count('Half Day');
    final percent = total == 0 ? 0.0 : (present + half) * 100 / total;
    final items = <Widget>[
      stat('Total Students', '$total', Icons.groups, Colors.blue),
      stat('Present', '$present', Icons.person, Colors.green),
      stat('Late Login', '${count('Late Login')}', Icons.schedule,
          Colors.orange),
      stat('Half Day', '$half', Icons.timelapse, Colors.purple),
      stat('Absent', '${count('Absent')}', Icons.person_off, Colors.red),
      stat('Attendance %', '${percent.toStringAsFixed(1)}%', Icons.pie_chart,
          Colors.blueAccent),
    ];
    return Column(children: [
      heading('Dashboard', "Today's attendance overview"),
      GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.45,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: items),
      const SizedBox(height: 16),
      SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
              onPressed: busy ? null : refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Dashboard')))
    ]);
  }

  Widget attendancePage() => Column(children: [
        heading('Face Attendance', 'Live face scanning inside this app'),
        card(Column(children: [
          const Text('Attendance Mode',
              style: TextStyle(
                  color: blue, fontWeight: FontWeight.bold, fontSize: 18)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('Check-Out'),
            Switch(
                value: checkIn,
                activeThumbColor: Colors.green,
                onChanged: (v) => setState(() {
                      checkIn = v;
                      lastSuccessfulStudent = null;
                      lastSuccessTime = null;
                    })),
            const Text('Check-In',
                style:
                    TextStyle(color: Colors.green, fontWeight: FontWeight.bold))
          ]),
          Text(
              checkIn
                  ? 'Right / ON: Record check-in time'
                  : 'Left / OFF: Record check-out time only',
              style: const TextStyle(color: Colors.black54, fontSize: 12))
        ])),
        const SizedBox(height: 14),
        card(Column(children: [
          const Text('Live Camera',
              style: TextStyle(
                  color: blue, fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 10),
          ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                  height: 260,
                  width: double.infinity,
                  decoration: BoxDecoration(
                      color: const Color(0xFFEAEAEA),
                      border: Border.all(
                          color: lastFaceMatched == null
                              ? Colors.grey
                              : (lastFaceMatched! ? Colors.green : Colors.red),
                          width: 4)),
                  child: camera != null && camera!.value.isInitialized
                      ? CameraPreview(camera!)
                      : const Center(child: Text('Camera is stopped')))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: scanning ? null : startScanner,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Camera'))),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: scanning ? stopScanner : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop Camera'))),
          ]),
          const SizedBox(height: 8),
          const Text(
              'Faces are checked automatically about every 3 seconds. No photo button or external camera app.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black54))
        ])),
        if (scanResult != null) ...[
          const SizedBox(height: 14),
          card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Attendance Status',
                style: TextStyle(color: blue, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...scanResult!.entries.map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('${e.key}: ${e.value}')))
          ]))
        ],
      ]);

  Future<void> registerStudent() async {
    try {
      final response = await http.post(Uri.parse('$root/api/students'),
          headers: headers,
          body: {
            'student_id': registerId,
            'name': registerName,
            'team': registerTeam
          });
      if (response.statusCode != 200) throw Exception(response.body);
      setState(() {
        enrollmentId = registerId;
        enrollmentSamples = 0;
        message = 'Registered $registerId. Capture at least five photos.';
      });
    } catch (e) {
      setState(() => message = 'Registration error: $e');
    }
  }

  Future<void> captureEnrollment() async {
    if (enrollmentId == null) {
      setState(() => message = 'Register student first');
      return;
    }
    CameraController? c;
    try {
      final cams = await availableCameras();
      final cam = cams.firstWhere(
          (x) => x.lensDirection == CameraLensDirection.front,
          orElse: () => cams.first);
      c = CameraController(cam, ResolutionPreset.medium, enableAudio: false);
      await c.initialize();
      final image = await c.takePicture();
      final request = http.MultipartRequest(
          'POST', Uri.parse('$root/api/enroll/$enrollmentId'));
      request.headers.addAll(headers);
      request.files.add(await http.MultipartFile.fromPath('photo', image.path));
      final response = await http.Response.fromStream(await request.send());
      if (response.statusCode != 200) throw Exception(response.body);
      final data = jsonDecode(response.body);
      setState(() {
        enrollmentSamples = data['samples'] ?? 0;
        message = 'Photo $enrollmentSamples saved. Capture at least five.';
      });
    } catch (e) {
      setState(() => message = 'Enrollment error: $e');
    } finally {
      await c?.dispose();
    }
  }

  Future<void> trainFaces() async {
    try {
      final response =
          await http.post(Uri.parse('$root/api/train'), headers: headers);
      if (response.statusCode != 200) throw Exception(response.body);
      setState(() => message = 'Model trained. You can scan registered faces.');
    } catch (e) {
      setState(() => message = 'Training error: $e');
    }
  }

  Widget registerPage() => Column(children: [
        heading(
            'Student Registration', 'Register a student and capture face data'),
        card(Column(children: [
          TextField(
              decoration: const InputDecoration(labelText: 'Student ID'),
              onChanged: (v) => registerId = v),
          TextField(
              decoration: const InputDecoration(labelText: 'Student Name'),
              onChanged: (v) => registerName = v),
          TextField(
              decoration: const InputDecoration(labelText: 'Team'),
              onChanged: (v) => registerTeam = v),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: registerStudent,
              child: const Text('Register Student')),
          const SizedBox(height: 8),
          Text(
              'Enrolling: ${enrollmentId ?? 'none'} — $enrollmentSamples samples'),
          OutlinedButton(
              onPressed: captureEnrollment,
              child: const Text('Capture Face Photo')),
          OutlinedButton(
              onPressed: trainFaces, child: const Text('Train Face Model')),
          const Text(
              'Capture at least five distinct photos per student before training. Photos are uploaded to your backend.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12)),
        ]))
      ]);

  Widget reportsPage() {
    final rows = (dashboard?['rows'] as List?) ?? [];
    return Column(children: [
      heading('Attendance Reports', 'Daily attendance records'),
      if (rows.isEmpty)
        card(const Text('No records loaded. Refresh the Dashboard first.')),
      ...rows
          .whereType<Map>()
          .map((r) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: card(Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${r['name'] ?? '-'}  •  ${r['id'] ?? '-'}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Team: ${r['team'] ?? '-'}'),
                    Text(
                        'In: ${r['check_in'] ?? '-'}   Out: ${r['check_out'] ?? '-'}'),
                    Text('Status: ${r['status'] ?? '-'}',
                        style: const TextStyle(color: blue)),
                  ]))))
          ,
    ]);
  }

  Widget settingsPage() => Column(children: [
        heading('Settings', 'Backend connection'),
        card(Column(children: [
          TextFormField(
              initialValue: server,
              decoration: const InputDecoration(
                  labelText: 'Server URL', hintText: 'http://192.168.x.x:8000'),
              onChanged: (v) => server = v),
          TextFormField(
              initialValue: username,
              decoration: const InputDecoration(labelText: 'Backend username'),
              onChanged: (v) => username = v.trim()),
          TextFormField(
              initialValue: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Backend password'),
              onChanged: (v) => password = v),
          const SizedBox(height: 12),
          SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: busy ? null : refresh,
                  child: const Text('Test Connection / Refresh'))),
          const Text(
              'For a physical phone, use your PC LAN IP on the same Wi-Fi. For cloud, use an HTTPS address. Never use public HTTP for credentials.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
        ]))
      ]);

  @override
  Widget build(BuildContext context) {
    final pages = [
      dashboardPage(),
      attendancePage(),
      registerPage(),
      reportsPage(),
      settingsPage()
    ];
    return Scaffold(
        body: SafeArea(
            child: Column(children: [
          Container(
              color: Colors.white,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Column(children: [
                Image.asset('assets/aj_logo.png',
                    height: 82, fit: BoxFit.contain),
                Text(DateTime.now().toString().substring(0, 16),
                    style: const TextStyle(color: blue, fontSize: 12)),
              ])),
          Expanded(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: Column(children: [
                    pages[tab],
                    if (busy)
                      const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator()),
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(message,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black54)))
                  ]))),
        ])),
        bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            onDestinationSelected: (i) {
              if (i != 1 && scanning) stopScanner();
              setState(() => tab = i);
            },
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.camera_alt_outlined),
                  selectedIcon: Icon(Icons.camera_alt),
                  label: 'Attendance'),
              NavigationDestination(
                  icon: Icon(Icons.person_add_alt_outlined),
                  selectedIcon: Icon(Icons.person_add_alt),
                  label: 'Register'),
              NavigationDestination(
                  icon: Icon(Icons.bar_chart_outlined),
                  selectedIcon: Icon(Icons.bar_chart),
                  label: 'Reports'),
              NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings'),
            ]));
  }
}
