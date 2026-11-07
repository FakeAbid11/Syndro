package dev.syndro.app

import kotlinx.coroutines.flow.MutableStateFlow

object ShareState {
    val running = MutableStateFlow(false)
    val port = MutableStateFlow(0)
    val urls = MutableStateFlow<List<ShareUrl>>(emptyList())
    val received = MutableStateFlow<List<StoredFile>>(emptyList())
    val error = MutableStateFlow<String?>(null)
}
