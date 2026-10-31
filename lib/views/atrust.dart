import 'dart:async';

import 'package:fl_clash/common/atrust.dart';
import 'package:fl_clash/common/atrust_auth.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class AtrustView extends ConsumerStatefulWidget {
  const AtrustView({super.key});

  @override
  ConsumerState<AtrustView> createState() => _AtrustViewState();
}

class _AtrustViewState extends ConsumerState<AtrustView> {
  late final TextEditingController _serverController;
  late final TextEditingController _usernameController;
  late final TextEditingController _loginDomainController;
  late String _tunnel;

  Timer? _poll;
  var _providers = <AtrustStatus>[];
  String? _selectedName;
  String? _sessionProvider;
  AtrustSession? _session;
  String? _listen;
  String? _error;
  var _busy = false;
  var _polling = false;

  AtrustAccount get _account => ref.read(appSettingProvider).atrust;

  AtrustStatus? get _status {
    final name = _selectedName;
    if (name == null) {
      return null;
    }
    for (final provider in _providers) {
      if (provider.name == name) {
        return provider;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final account = _account;
    _serverController = TextEditingController(text: account.server);
    _usernameController = TextEditingController(text: account.username);
    _loginDomainController = TextEditingController(text: account.loginDomain);
    _tunnel = account.tunnel;
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _serverController.dispose();
    _usernameController.dispose();
    _loginDomainController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final listen = await ref.read(coreHandlerProvider).getAuthListen();
      if (!mounted) {
        return;
      }
      if (listen.isEmpty) {
        _stopPolling();
        setState(() {
          _listen = null;
          _providers = <AtrustStatus>[];
          _selectedName = null;
          _error = null;
        });
        return;
      }
      final providers = await AtrustAuthApi(listen).providers();
      if (!mounted) {
        return;
      }
      _applyProviders(listen, providers);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  void _applyProviders(String listen, List<AtrustStatus> providers) {
    final ordered = [...providers]
      ..sort((a, b) {
        if (a.name == atrustProxyName) {
          return -1;
        }
        if (b.name == atrustProxyName) {
          return 1;
        }
        return a.name.compareTo(b.name);
      });
    final selected = _pickSelected(ordered);
    final status = ordered
        .where((provider) => provider.name == selected)
        .firstOrNull;
    setState(() {
      _listen = listen;
      _providers = ordered;
      _selectedName = selected;
      _error = status?.error.isNotEmpty == true ? status!.error : null;
      if (status?.isReady == true ||
          status?.state == 'error' ||
          status?.state == 'expired' ||
          status == null) {
        _busy = false;
      }
    });
    if (ordered.any((provider) => provider.isPending)) {
      _startPolling();
    } else {
      _stopPolling();
    }
  }

  String? _pickSelected(List<AtrustStatus> providers) {
    return selectAtrustProviderName(providers, _selectedName);
  }

  void _selectProvider(String name) {
    setState(() {
      _selectedName = name;
      final status = _status;
      _error = status?.error.isNotEmpty == true ? status!.error : null;
    });
    if (_status?.isPending == true) {
      _startPolling();
    }
  }

  void _startPolling() {
    if (_poll != null) {
      return;
    }
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollOnce());
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _pollOnce() async {
    if (_polling || _listen == null) {
      return;
    }
    _polling = true;
    try {
      final providers = await AtrustAuthApi(_listen!).providers();
      if (!mounted) {
        return;
      }
      _applyProviders(_listen!, providers);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _busy = false;
        });
      }
      _stopPolling();
    } finally {
      _polling = false;
    }
  }

  Future<void> _saveAccount() async {
    final server = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final loginDomain = _loginDomainController.text.trim();
    if (server.isEmpty || username.isEmpty) {
      setState(() => _error = context.appLocalizations.atrustRequiredFields);
      return;
    }
    final account = AtrustAccount(
      server: server,
      port: _account.port,
      loginDomain: loginDomain.isEmpty ? 'Radius' : loginDomain,
      authType: _account.authType,
      username: username,
      tunnel: _tunnel,
    );
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(atrust: account));
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await ref.read(setupActionProvider.notifier).applyProfile(force: true);
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await _createSession();
      if (!mounted) {
        return;
      }
      setState(() {
        _session = session;
        _sessionProvider = _status?.name;
      });
      final opened = await launchUrl(
        Uri.parse(session.url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw const AtrustAuthException('Could not open the sign-in page.');
      }
      _startPolling();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<AtrustSession> _createSession() async {
    final notActive = context.appLocalizations.atrustNotActive;
    AtrustAuthException? last;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _refresh();
      final listen = _listen;
      final status = _status;
      if (listen == null || listen.isEmpty || status == null) {
        throw AtrustAuthException(notActive, retryable: attempt == 0);
      }
      try {
        return await AtrustAuthApi(listen).createSession(status.name);
      } on AtrustAuthException catch (e) {
        last = e;
        if (!e.retryable || attempt == 1) {
          rethrow;
        }
        _listen = null;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw last ??
        const AtrustAuthException('aTrust auth listener is unavailable');
  }

  Future<void> _cancelLogin() async {
    final session = _session;
    _stopPolling();
    if (session != null && _listen != null) {
      try {
        await AtrustAuthApi(_listen!).cancelSession(session.id);
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _session = null;
        _sessionProvider = null;
      });
      await _refresh();
    }
  }

  Future<void> _logout() async {
    final notActive = context.appLocalizations.atrustNotActive;
    final name = _status?.name;
    if (name == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      Object? lastError;
      for (var attempt = 0; attempt < 2; attempt++) {
        await _refresh();
        final listen = _listen;
        if (listen == null) {
          lastError = notActive;
          break;
        }
        try {
          await AtrustAuthApi(listen).logout(name);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      }
      if (mounted && lastError != null) {
        setState(() => _error = lastError.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
      await _refresh();
    }
  }

  String _stateLabel(AppLocalizations l) {
    final state = _status?.state;
    if (state == 'ready') {
      return l.atrustConnected;
    }
    if (state == 'pending' || state == 'awaiting_input') {
      return l.atrustWaiting;
    }
    if (state == 'expired') {
      return l.atrustExpired;
    }
    if (state == 'error') {
      return l.atrustLoginFailed;
    }
    return l.atrustNotSignedIn;
  }

  Future<void> _disableBypass() async {
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(bypassPrivateRoute: false));
    await ref.read(setupActionProvider.notifier).applyProfile(force: true);
  }

  Widget _buildBypassWarning(AppLocalizations l) {
    return CommonCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const GlyphIcon(AppGlyphs.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.atrustTunBypassTitle,
                  style: AppTextStyle.headline.of(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l.atrustTunBypassDesc),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TonalButton(
              label: l.atrustDisableBypass,
              onPressed: _busy ? null : _disableBypass,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final provider in _providers)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: TonalChip(
                label: provider.name,
                color: provider.name == _selectedName
                    ? context.colorScheme.primaryContainer
                    : context.colorScheme.surfaceContainerHighest,
                foregroundColor: provider.name == _selectedName
                    ? context.colorScheme.onPrimaryContainer
                    : context.colorScheme.onSurfaceVariant,
                onPressed: () => _selectProvider(provider.name),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(AppLocalizations l) {
    final account = _account;
    final status = _status;
    final pending =
        status?.isPending == true ||
        (_busy && _session != null && _sessionProvider == status?.name);
    final ready = status?.isReady == true;
    final server = status?.server.isNotEmpty == true
        ? '${status!.server}:${status.port}'
        : '${account.server}:${account.port}';
    final accountLabel = status?.account.isNotEmpty == true
        ? status!.account
        : status?.name == atrustProxyName
        ? account.username
        : (status?.name ?? account.username);
    return CommonCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const GlyphIcon(AppGlyphs.lock),
              const SizedBox(width: 12),
              Expanded(
                child: Text(l.atrust, style: AppTextStyle.title3.of(context)),
              ),
              TonalChip(
                label: _stateLabel(l),
                color: ready
                    ? context.colorScheme.primaryContainer
                    : context.colorScheme.surfaceContainerHighest,
                foregroundColor: ready
                    ? context.colorScheme.onPrimaryContainer
                    : context.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(server),
          if (accountLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              accountLabel,
              style: TextStyle(color: context.colorScheme.onSurfaceVariant),
            ),
          ],
          if (ready && status != null) ...[
            const SizedBox(height: 12),
            Text(
              l.atrustResourceSummary(status.domains, status.cidrs),
              style: TextStyle(color: context.colorScheme.onSurfaceVariant),
            ),
          ],
          if (pending) ...[
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TonalButton(
                label: l.cancel,
                onPressed: _busy ? _cancelLogin : null,
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TonalButton(
                  glyph: AppGlyphs.lockOpen,
                  label: ready ? l.atrustSignInAgain : l.atrustSignIn,
                  onPressed: _busy ? null : _login,
                ),
                if (ready)
                  TonalButton(
                    label: l.atrustSignOut,
                    onPressed: _busy ? null : _logout,
                  ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: context.colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _buildProfileSettings(AppLocalizations l) {
    final profileId = ref.watch(currentProfileIdProvider);
    if (profileId == null || !_account.isConfigured) {
      return const SizedBox.shrink();
    }
    return generateSection(
      title: l.atrustProfile,
      items: [
        ConfigToggleItem(
          title: (_) => l.atrustApplyToProfile,
          selector: profileProvider(
            profileId,
          ).select((profile) => profile?.overrides.atrust.enabled ?? true),
          onChanged: (ref, value) => _updateProfileSettings(
            ref,
            (settings) => settings.copyWith(enabled: value),
          ),
        ),
        ConfigToggleItem(
          title: (_) => l.atrustManagedRules,
          selector: profileProvider(
            profileId,
          ).select((profile) => profile?.overrides.atrust.managedRules ?? true),
          onChanged: (ref, value) => _updateProfileSettings(
            ref,
            (settings) => settings.copyWith(managedRules: value),
          ),
        ),
        ConfigToggleItem(
          title: (_) => l.atrustManagedDns,
          selector: profileProvider(
            profileId,
          ).select((profile) => profile?.overrides.atrust.managedDns ?? true),
          onChanged: (ref, value) => _updateProfileSettings(
            ref,
            (settings) => settings.copyWith(managedDns: value),
          ),
        ),
      ],
    );
  }

  void _updateProfileSettings(
    WidgetRef ref,
    AtrustProfileSettings Function(AtrustProfileSettings settings) update,
  ) {
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId == null) {
      return;
    }
    ref
        .read(profilesProvider.notifier)
        .updateProfile(
          profileId,
          (profile) => profile.copyWith(
            overrides: profile.overrides.copyWith(
              atrust: update(profile.overrides.atrust),
            ),
          ),
        );
    unawaited(ref.read(setupActionProvider.notifier).applyProfile(force: true));
  }

  Widget _buildAccountForm(AppLocalizations l) {
    return generateSection(
      title: l.atrustGlobalAccount,
      items: [
        CommonCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _serverController,
                decoration: InputDecoration(
                  labelText: l.server,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: l.username,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _loginDomainController,
                decoration: InputDecoration(
                  labelText: l.atrustLoginDomain,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _tunnel,
                decoration: InputDecoration(
                  labelText: l.atrustTunnelMode,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(value: 'l3', child: Text(l.atrustTunnelL3)),
                  DropdownMenuItem(
                    value: 'tcp',
                    child: Text(l.atrustTunnelTcp),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _tunnel = value);
                  }
                },
              ),
              const SizedBox(height: 16),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  onPressed: _busy ? null : _saveAccount,
                  child: Text(l.atrustSave),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final hasProviders = _providers.isNotEmpty;
    final profileId = ref.watch(currentProfileIdProvider);
    final profile = profileId == null
        ? null
        : ref.watch(profileProvider(profileId));
    final showBypassWarning =
        hasProviders &&
        profile != null &&
        profile.overrides.atrust.enabled &&
        ref.watch(
          patchClashConfigProvider.select((state) => state.tun.enable),
        ) &&
        ref.watch(
          networkSettingProvider.select((state) => state.bypassPrivateRoute),
        );
    return CommonScaffold(
      title: l.atrust,
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.sectionsTopPadding,
          bottom: 24 + context.bottomInset,
        ),
        children: [
          if (hasProviders) ...[
            _buildProviderTabs(),
            const SizedBox(height: 12),
            _buildStatusCard(l),
          ] else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                l.atrustNotActive,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          if (showBypassWarning) ...[
            const SizedBox(height: 16),
            _buildBypassWarning(l),
          ],
          _buildProfileSettings(l),
          _buildAccountForm(l),
        ],
      ),
    );
  }
}
