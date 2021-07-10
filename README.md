Observable and signal/slot implementation
=========================================

This library provides event handling mechanisms on two abstraction levels.
Signals/slots are a direct way for events to be propagated to any number of
event receivers. The propagation happens synchronously and has very low
overhead, computationally and memory consumption wise.

Observables on the other hand allow each observer to process events
asynchronously using a separate event queue. The advantage of this approach is
that each observer can process events in order, but independent of the timing
of the source. Additionally, observables can be composed, manipulated and
augmented using a range-like API.

Both, signals and observables, support storing extra data to avoid the need for
creating heap closures when listening for events.

![Build status](https://github.com/s-ludwig/observable/actions/workflows/ci.yml/badge.svg?branch=master)


Signal/slot example
-------------------

```D
class Slider {
    private {
        double m_value = 0.0;
        Signal!double m_valueChangeSignal;
    }

    @property ref SignalSocket!double valueChangeSignal()
    {
        return m_valueChangeSignal.socket;
    }

    @property void value(double new_value)
    {
        m_value = new_value;
        m_valueChangeSignal.emit(new_value);
    }
}

class Label {
    @property void caption(string caption);
}

class MyDialog {
    private {
        Label m_label;
        Slider m_slider;
        SignalConnection m_valueConnection;
    }

    this()
    {
        m_label = new Label;

        m_slider = new Slider;
        m_slider.valueChangeSignal.connect(m_valueConnection,
            (value) => slider.caption = value.to!string);
    }
}
```

Observable example
------------------

```D
class Slider {
    private {
        double m_value = 0.0;
        ObservableSource!double m_valueChanges;
    }

    @property ref Observable!double valueChanges()
    {
        return m_valueChanges.observable;
    }

    @property void value(double new_value)
    {
        m_value = new_value;
        m_valueChanges.put(new_value);
    }
}

class Label {
    @property void caption(string caption);
}

class MyDialog {
    private {
        Label m_label;
        Slider m_slider;
        SignalConnection m_valueConnection;
    }

    this()
    {
        m_label = new Label;

        m_slider = new Slider;

        runTask({
            foreach (value; m_slider.valueChanges.subscribe)
                m_label.caption = value.to!string;
        });
    }
}
```
