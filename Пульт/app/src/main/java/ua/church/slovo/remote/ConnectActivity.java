package ua.church.slovo.remote;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

/// Экран подключения: найденные в сети компьютеры и ручной ввод адреса.
public final class ConnectActivity extends Activity {

    private Settings settings;
    private Discovery discovery;
    private LinearLayout foundList;
    private TextView searchStatus;
    private EditText host;
    private EditText port;
    private EditText pin;
    private int foundCount;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        setContentView(R.layout.activity_connect);
        settings = new Settings(this);

        foundList = findViewById(R.id.foundList);
        searchStatus = findViewById(R.id.searchStatus);
        host = findViewById(R.id.host);
        port = findViewById(R.id.port);
        pin = findViewById(R.id.pin);

        host.setText(settings.host());
        port.setText(String.valueOf(settings.port()));
        pin.setText(settings.pin());

        findViewById(R.id.connect).setOnClickListener(v -> connectManually());
        findViewById(R.id.rescan).setOnClickListener(v -> restartDiscovery());
    }

    @Override
    protected void onResume() {
        super.onResume();
        restartDiscovery();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (discovery != null) discovery.stop();
    }

    private void restartDiscovery() {
        if (discovery != null) discovery.stop();
        foundList.removeAllViews();
        foundCount = 0;
        searchStatus.setText(R.string.searching);
        discovery = new Discovery(this, new Discovery.Listener() {
            @Override public void found(String name, String address, int found) {
                foundCount++;
                searchStatus.setText("");
                Button row = new Button(ConnectActivity.this, null, 0, R.style.BigButton);
                row.setText(name + "\n" + address + ":" + found);
                row.setAllCaps(false);
                row.setOnClickListener(v -> finishWith(address, found, pin.getText().toString(), name));
                foundList.addView(row);
            }

            @Override public void finished() {
                if (foundCount == 0) searchStatus.setText(R.string.nothing_found);
            }
        });
        discovery.start();
    }

    private void connectManually() {
        String address = host.getText().toString().trim();
        if (address.isEmpty()) {
            Toast.makeText(this, R.string.host_missing, Toast.LENGTH_SHORT).show();
            return;
        }
        int number;
        try {
            number = Integer.parseInt(port.getText().toString().trim());
        } catch (NumberFormatException error) {
            number = 8103;
        }
        finishWith(address, number, pin.getText().toString(), "");
    }

    private void finishWith(String address, int number, String code, String name) {
        settings.save(address, number, code, name);
        // Куди далі — каже сама програма: у пульта й планшета вікно
        // з'єднання спільне, а робочі екрани різні.
        Intent intent = new Intent();
        intent.setClassName(this, getString(R.string.work_activity));
        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(intent);
        finish();
    }
}
